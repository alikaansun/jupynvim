-- Mouse-controlled matplotlib zoom/pan for inline figures.
--
-- jupynvim renders plots as static PNGs (Kitty graphics), so there is no
-- ipympl/widget canvas to drive. This module fakes the interactive feel with a
-- comm-free bridge:
--
--   1. A Python helper (_jupynvim_mpl) is installed into the kernel the first
--      time interactive mode is used. It locates the cell's figure (via Gcf or
--      a gc scan for the user's `fig`, which survives inline's auto-close) and
--      exposes pan / box_zoom / reset ops that mutate axis limits and return
--      the Figure.
--   2. Entering interactive mode (<leader>nz) captures the current cell's
--      figure. Mouse drags over the figure are translated to fractional
--      coordinates and sent to the helper via the `mpl_op` RPC.
--   3. The backend runs the op history-lessly, captures the re-rendered PNG
--      (never touching the cell's outputs), and returns it. We repaint the
--      existing Kitty image in place via Image.update_bytes.
--
-- See core/src/rpc/mpl.rs and the plan for the full round-trip.

local Image = require("jupynvim.notebook.image")
local Connect = require("jupynvim.backend.connect")

local M = {}

-- Only one cell is interactive at a time. Toggling on a different cell switches.
-- state = { buf, win, nb, cell_id, range, mode, drag, saved_mouse, keys }
M._active = nil

-- ── embedded kernel helper ───────────────────────────────────────────────
-- Installed once per python kernel via execute_silent. dispatch_b64 decodes a
-- base64 JSON payload { cell_id, op, args } and returns the (possibly mutated)
-- Figure so the inline backend renders a fresh PNG the backend can capture.
local HELPER_PY = [==[
try:
    import json as _json, base64 as _b64, gc as _gc
    import matplotlib.figure as _mfig
    from matplotlib._pylab_helpers import Gcf as _Gcf

    class _JupynvimMpl:
        def __init__(self):
            self.registry = {}    # cell_id -> Figure
            self.original = {}    # cell_id -> [(ax, xlim, ylim), ...]

        def _find_figure(self):
            # An open figure (kept in Gcf) wins. Under the default inline
            # backend the cell's figure is already closed by the time we get
            # here, but the user's `fig` variable still references it, so a gc
            # scan recovers it — and a closed Figure re-renders fine (its axes
            # and limits persist). Prefer the highest-numbered figure so the
            # most recently created plot wins.
            mgrs = _Gcf.get_all_fig_managers()
            if mgrs:
                return mgrs[-1].canvas.figure
            figs = [o for o in _gc.get_objects()
                    if isinstance(o, _mfig.Figure) and o.axes]
            if not figs:
                return None
            return max(figs, key=lambda f: getattr(f, 'number', 0) or 0)

        @staticmethod
        def _rectilinear(ax):
            return getattr(ax, 'name', 'rectilinear') == 'rectilinear'

        def _axes_at(self, fig, fx, fy):
            px = fx * fig.bbox.width
            py = (1.0 - fy) * fig.bbox.height  # display origin is bottom-left
            for ax in reversed(fig.axes):
                try:
                    if ax.bbox.contains(px, py) and self._rectilinear(ax):
                        return ax, px, py
                except Exception:
                    pass
            for ax in fig.axes:
                if self._rectilinear(ax):
                    return ax, px, py
            return None, px, py

        @staticmethod
        def _px(fig, fx, fy):
            return fx * fig.bbox.width, (1.0 - fy) * fig.bbox.height

        @staticmethod
        def _data(ax, px, py):
            return ax.transData.inverted().transform((px, py))

        def begin(self, cell_id, args):
            fig = self._find_figure()
            if fig is None:
                return None
            self.registry[cell_id] = fig
            self.original[cell_id] = [(ax, ax.get_xlim(), ax.get_ylim())
                                      for ax in fig.axes]
            return fig

        def pan(self, cell_id, args):
            fig = self.registry.get(cell_id)
            if fig is None:
                return None
            ax, px0, py0 = self._axes_at(fig, args['x0'], args['y0'])
            if ax is None:
                return fig
            px1, py1 = self._px(fig, args['x1'], args['y1'])
            x0, y0 = self._data(ax, px0, py0)
            x1, y1 = self._data(ax, px1, py1)
            dx, dy = x0 - x1, y0 - y1  # move data under the cursor
            xlo, xhi = ax.get_xlim()
            ylo, yhi = ax.get_ylim()
            ax.set_xlim(xlo + dx, xhi + dx)
            ax.set_ylim(ylo + dy, yhi + dy)
            return fig

        def box_zoom(self, cell_id, args):
            fig = self.registry.get(cell_id)
            if fig is None:
                return None
            ax, px0, py0 = self._axes_at(fig, args['x0'], args['y0'])
            if ax is None:
                return fig
            px1, py1 = self._px(fig, args['x1'], args['y1'])
            x0, y0 = self._data(ax, px0, py0)
            x1, y1 = self._data(ax, px1, py1)
            if x0 == x1 or y0 == y1:
                return fig
            ax.set_xlim(min(x0, x1), max(x0, x1))
            ax.set_ylim(min(y0, y1), max(y0, y1))
            return fig

        def reset(self, cell_id, args):
            fig = self.registry.get(cell_id)
            if fig is None:
                return None
            for ax, xl, yl in self.original.get(cell_id, []):
                try:
                    ax.set_xlim(xl)
                    ax.set_ylim(yl)
                except Exception:
                    pass
            return fig

        def end(self, cell_id, args):
            fig = self.registry.pop(cell_id, None)
            self.original.pop(cell_id, None)
            return fig

        def dispatch_b64(self, s):
            try:
                p = _json.loads(_b64.b64decode(s).decode('utf-8'))
            except Exception:
                return None
            op = p.get('op')
            if op not in ('begin', 'pan', 'box_zoom', 'reset', 'end'):
                return None
            cell_id = p.get('cell_id')
            args = p.get('args') or {}
            try:
                return getattr(self, op)(cell_id, args)
            except Exception:
                return self.registry.get(cell_id)

    try:
        _jupynvim_mpl
    except NameError:
        _jupynvim_mpl = _JupynvimMpl()
except Exception:
    pass
]==]

-- Install the kernel helper on demand (python kernels only), once per session.
-- Lazy: sent the first time interactive mode is entered, so nothing runs in the
-- kernel unless the feature is used. Idempotent — the helper only (re)defines
-- _jupynvim_mpl if it isn't already there.
M._installed = {}
function M.install(nb, cl)
  if not nb or not cl or not nb.session_id then return end
  if M._installed[nb.session_id] then return end
  M._installed[nb.session_id] = true
  cl:call("execute_silent", { session_id = nb.session_id, code = HELPER_PY }, function() end)
end

-- ── geometry: map a mouse cell to a fraction of the figure ────────────────
-- The placeholder image occupies rows×cols terminal cells anchored just below
-- the cell's last source line (see render.lua build_image_virt_lines). We reuse
-- the same screenpos anchor place_images uses for the kitty renderer. The two
-- offsets are configurable because exact placement depends on wrap/gutter.
local function figure_box(st)
  local rows, cols = Image.placement_geom(st.cell_id)
  if not rows or not cols then return nil end
  local buf, win = st.buf, st.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    win = vim.fn.bufwinid(buf)
    st.win = win
  end
  if not win or win == -1 then return nil end
  -- Mirror render.lua place_images: the image's top-left is 2 rows below the
  -- screen row of the line after the source (past the footer border), and one
  -- OUT_INDENT in from buffer column 1. screenpos is absolute, so this stays
  -- correct in vertical splits. Both offsets are overridable because exact
  -- placement shifts with wrapped source lines and gutter width.
  local total = vim.api.nvim_buf_line_count(buf)
  local anchor = math.min(st.range.stop, total)
  local pos = vim.fn.screenpos(win, anchor, 1)
  if not pos or not pos.row or pos.row == 0 then return nil end
  local cfg = require("jupynvim").config or {}
  return {
    top = pos.row + (cfg.mpl_row_offset or 2),
    left = pos.col + (cfg.mpl_col_offset or 2),
    rows = rows,
    cols = cols,
  }
end

-- Fraction (fx,fy) in [0,1] of the current mouse position over the figure, or
-- nil if the pointer is well outside it. y grows top→bottom.
local function mouse_fraction(st)
  local box = figure_box(st)
  if not box then return nil end
  local mp = vim.fn.getmousepos()
  if not mp or not mp.screenrow then return nil end
  local fx = (mp.screencol - box.left) / math.max(box.cols - 1, 1)
  local fy = (mp.screenrow - box.top) / math.max(box.rows - 1, 1)
  if fx < -0.25 or fx > 1.25 or fy < -0.25 or fy > 1.25 then return nil end
  fx = math.max(0, math.min(1, fx))
  fy = math.max(0, math.min(1, fy))
  return fx, fy
end

-- ── op round-trip ─────────────────────────────────────────────────────────
local function set_cell_png(nb, cell_id, png_b64)
  -- Keep the Lua-side cell output in sync so a full Render.refresh repaints the
  -- zoomed view instead of reverting to the original PNG. Backend/disk state is
  -- untouched, so :w still saves the original figure.
  local cell = nb.get_cell and nb:get_cell(cell_id)
  if not cell or not cell.outputs then return end
  for _, o in ipairs(cell.outputs) do
    if (o.output_type == "execute_result" or o.output_type == "display_data") and o.data then
      if o.data["image/png"] or o.data["image/jpeg"] or o.data["image/gif"] then
        o.data["image/png"] = png_b64
        o.data["image/gif"] = nil  -- our render is a single static frame now
        o.data["image/jpeg"] = nil
        return
      end
    end
  end
end

local function call_op(op, args)
  local st = M._active
  if not st then return end
  local cl = Connect._nb_client(st.nb)
  if not cl then return end
  cl:call("mpl_op", {
    session_id = st.nb.session_id,
    cell_id = st.cell_id,
    op = op,
    args = args or vim.empty_dict(),
  }, function(err, res)
    if err then return end  -- op no-op'd (e.g. no figure); leave the view as-is
    if res and res.png_b64 and res.png_b64 ~= "" then
      vim.schedule(function()
        set_cell_png(st.nb, st.cell_id, res.png_b64)
        Image.update_bytes(st.cell_id, res.png_b64)
      end)
    end
  end)
end

-- ── mode entry / exit ─────────────────────────────────────────────────────
local function hint(st)
  vim.notify(
    ("jupynvim plot [%s mode] — z: box-zoom  p: pan  r: reset  <Esc>/q: exit")
      :format(st.mode),
    vim.log.levels.INFO)
end

local function set_mode(mode)
  local st = M._active
  if not st then return end
  st.mode = mode
  hint(st)
end

-- Left press: record drag start fraction.
local function on_press()
  local st = M._active
  if not st then return end
  local fx, fy = mouse_fraction(st)
  st.drag = (fx and { x0 = fx, y0 = fy }) or nil
end

-- Left release: apply the drag as a box-zoom or pan on the target axes.
local function on_release()
  local st = M._active
  if not st or not st.drag then return end
  local fx, fy = mouse_fraction(st)
  local d = st.drag
  st.drag = nil
  if not fx then return end
  if st.mode == "pan" then
    call_op("pan", { x0 = d.x0, y0 = d.y0, x1 = fx, y1 = fy })
  else
    -- Ignore accidental micro-drags (a plain click).
    if math.abs(fx - d.x0) < 0.02 and math.abs(fy - d.y0) < 0.02 then return end
    call_op("box_zoom", { x0 = d.x0, y0 = d.y0, x1 = fx, y1 = fy })
  end
end

local MODE_KEYS = {
  z = function() set_mode("zoom") end,
  p = function() set_mode("pan") end,
  r = function() call_op("reset") end,
}

local OVERRIDE_KEYS = { "<LeftMouse>", "<LeftRelease>", "<LeftDrag>", "z", "p", "r", "q", "<Esc>" }

-- Some of these keys already carry buffer-local maps (cellmode binds
-- <LeftRelease> and <Esc>). Snapshot them so exit restores the originals
-- instead of leaving the keys unbound.
local function snapshot_maps(keys)
  local saved = {}
  for _, k in ipairs(keys) do
    local m = vim.fn.maparg(k, "n", false, true)
    if type(m) == "table" and m.buffer == 1 and m.lhs then saved[k] = m end
  end
  return saved
end

local function enable_maps(st)
  local buf = st.buf
  local opts = { buffer = buf, silent = true, nowait = true }
  st.saved_maps = snapshot_maps(OVERRIDE_KEYS)
  -- Mouse: own press/release so clicks drive zoom/pan instead of moving the cursor.
  vim.keymap.set("n", "<LeftMouse>", function() on_press() end, opts)
  vim.keymap.set("n", "<LeftRelease>", function() on_release() end, opts)
  vim.keymap.set("n", "<LeftDrag>", function() end, opts)
  for k, fn in pairs(MODE_KEYS) do
    vim.keymap.set("n", k, fn, opts)
  end
  vim.keymap.set("n", "q", function() M.exit() end, opts)
  vim.keymap.set("n", "<Esc>", function() M.exit() end, opts)
end

local function disable_maps(st)
  if not (st and st.buf and vim.api.nvim_buf_is_valid(st.buf)) then return end
  for _, k in ipairs(OVERRIDE_KEYS) do
    pcall(vim.keymap.del, "n", k, { buffer = st.buf })
    local m = (st.saved_maps or {})[k]
    if m then pcall(vim.fn.mapset, "n", false, m) end
  end
end

-- end() the kernel session for a state that may no longer be M._active.
local function call_session_end(st)
  local cl = Connect._nb_client(st.nb)
  if cl then
    cl:call("mpl_op", {
      session_id = st.nb.session_id, cell_id = st.cell_id,
      op = "end", args = vim.empty_dict(),
    }, function() end)
  end
end

function M.exit()
  local st = M._active
  if not st then return end
  M._active = nil
  call_session_end(st)
  disable_maps(st)
  if st.saved_mouse ~= nil then vim.o.mouse = st.saved_mouse end
  vim.notify("jupynvim: interactive plot mode off", vim.log.levels.INFO)
end

-- Toggle interactive mode on the cell under the cursor. Bound to <leader>nz
-- (keymaps.lua calls this directly).
function M.toggle(buf)
  local Notebook = require("jupynvim.notebook.init")
  local nb = Notebook.get(buf)
  if not nb then return end

  -- Already active on this cell → turn off.
  if M._active and M._active.buf == buf then
    local lnum0 = vim.api.nvim_win_get_cursor(0)[1]
    local cur = select(1, nb:cell_at_line(lnum0))
    if cur == M._active.cell_id then
      M.exit()
      return
    end
    -- Different cell: exit the old session first, then fall through.
    M.exit()
  end

  if not Image.supported() then
    vim.notify("jupynvim: interactive plots need a Kitty-graphics terminal", vim.log.levels.WARN)
    return
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cell_id, range = nb:cell_at_line(lnum)
  if not cell_id then return end
  local cell = nb:get_cell(cell_id)
  if not cell or cell.cell_type ~= "code" then
    vim.notify("jupynvim: not a code cell", vim.log.levels.WARN)
    return
  end
  if not Image.placement_geom(cell_id) then
    vim.notify("jupynvim: no figure in this cell (run a plot cell first)", vim.log.levels.WARN)
    return
  end

  local st = {
    buf = buf,
    win = vim.fn.bufwinid(buf),
    nb = nb,
    cell_id = cell_id,
    range = range,
    mode = "zoom",
    drag = nil,
    saved_mouse = vim.o.mouse,
  }
  M._active = st
  vim.o.mouse = "a"
  -- Lazily install the kernel helper (once per session), then capture the
  -- figure. Both go on the kernel's shell queue, so install runs before begin.
  M.install(nb, Connect._nb_client(nb))
  enable_maps(st)
  call_op("begin")
  hint(st)
end

return M
