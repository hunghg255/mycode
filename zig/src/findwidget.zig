//! The find widget over the top right of the editor, as the Go app's
//! `findView`: the arrow that shows the replace row, the query with the
//! toggles of case, whole words and regular expressions inside it, the
//! count of matches ("3 of 12", "No results" in red), the previous and next
//! match, closing; then the replacement with Replace and Replace All. The
//! editor finds and marks the matches (`CodeEditor.own_find_bar`).
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const icons = @import("icons.zig");
const Doc = @import("doc.zig").Doc;

/// The width of the count, so the buttons after it don't move.
const count_w = 74;

/// A button with an icon and a tooltip; false while disabled.
fn iconButton(c: *ui.Context, icon: []const u8, tip: []const u8, disabled: bool) bool {
    const t = c.theme;
    const b = ui.div(c).w(26).h(24).center().rounded(4);
    if (!disabled) _ = b.hover(t.surface_hover);
    icons.sym(c, icon, .{ .size = 11.5, .color = if (disabled) t.muted.alpha(0.45) else t.text });
    const bi = b.interaction();
    b.end();
    ui.tooltip(c, bi, tip);
    return bi.clicked and !disabled;
}

/// An option of finding, as Match Case: shown pressed while on; a click
/// flips it.
pub fn toggle(c: *ui.Context, icon: []const u8, tip: []const u8, on: *bool) void {
    const t = c.theme;
    const b = ui.div(c).w(22).h(20).center().rounded(4);
    if (on.*) _ = b.bg(t.accent.alpha(0.2)).border(t.accent.alpha(0.6)) else _ = b.hover(t.surface_hover);
    icons.sym(c, icon, .{ .size = 11, .color = if (on.*) t.text else t.muted });
    const bi = b.interaction();
    b.end();
    ui.tooltip(c, bi, tip);
    if (bi.clicked) {
        on.* = !on.*;
        c.changed = true;
    }
}

/// A field of the widget in its frame, which takes the keyboard when
/// `focus` asks; its id goes to `id`.
fn field(c: *ui.Context, buf: *ui.TextBuffer, id: *u64, focus: bool, placeholder: []const u8) ui.TextFieldResult {
    id.* = c.peekId(null);
    if (focus) {
        c.focus = id.*;
        c.changed = true;
    }
    return ui.textField(c, buf, .{ .placeholder = placeholder, .width = .fill, .size = 12.5, .bare = true, .label = placeholder });
}

/// The widget, laid over the editor at `at` (its rect in the parent).
pub fn view(c: *ui.Context, d: *Doc, at: ui.Rect, editor_bg: ui.Color) void {
    const ed = &d.editor;
    const f = &ed.find;
    if (!f.open) return;
    const t = c.theme;
    const ta = &ed.area;
    if (ui.findBarEscaped(c, ed.query_id) or ui.findBarEscaped(c, ed.replacement_id)) return ed.closeBars();
    const w = @min(430, at.w - 30);
    if (w < 200) return;
    const box = ui.div(c).column().absolute().offset(at.x + at.w - 22 - w, at.y + 4).w(w).px(6).py(5).gap(4).rounded(8).bg(t.surface).border(t.border).shadowMd();
    defer box.end();
    const n = f.matches.items.len;
    {
        const row = ui.div(c).row().wFull().gap(4).itemsCenter();
        defer row.end();
        const arrow = ui.div(c).w(18).h(22).center().rounded(4).hover(t.surface_hover);
        icons.sym(c, if (f.replacing) "chevron.down" else "chevron.right", .{ .size = 10, .color = t.muted });
        const ai = arrow.interaction();
        arrow.end();
        ui.tooltip(c, ai, "Toggle Replace");
        if (ai.clicked) {
            f.replacing = !f.replacing;
            c.changed = true;
        }
        const focused = c.focus == ed.query_id and ed.query_id != 0;
        const frame = ui.div(c).row().grow().h(26).pl(8).pr(4).gap(2).itemsCenter().rounded(5).bg(editor_bg).border(if (focused) t.accent.alpha(0.7) else t.border);
        const want = ed.focus_next == .query;
        if (want) ed.focus_next = .none;
        const q = field(c, &f.query, &ed.query_id, want, "Find");
        if (q.changed) {
            // As the query is typed, the first match from the selection.
            f.update(ta.doc.gpa, &ta.doc);
            f.current = null;
            if (f.matches.items.len > 0) {
                ta.collapse(ta.sel.lo());
                f.step(ta, false);
            }
        }
        if (q.submitted) {
            f.update(ta.doc.gpa, &ta.doc);
            f.step(ta, c.input.shift);
        }
        toggle(c, "case", "Match Case", &f.flags.case);
        toggle(c, "word", "Match Whole Word", &f.flags.word);
        toggle(c, "regex", "Use Regular Expression", &f.flags.regex);
        frame.end();
        const count = if (f.bad_pattern)
            "Invalid pattern"
        else if (f.query.len == 0)
            ""
        else if (n == 0)
            "No results"
        else if (f.current) |i|
            c.print("{d} of {d}{s}", .{ i + 1, n, if (n >= f.limit) "+" else "" })
        else
            c.print("{d} of {d}{s}", .{ 0, n, if (n >= f.limit) "+" else "" });
        const cb = ui.div(c).w(count_w).center();
        ui.text(c, count, .{ .size = 11.5, .color = if (f.bad_pattern or (n == 0 and f.query.len > 0)) t.danger else t.muted });
        cb.end();
        if (iconButton(c, "arrow.up", "Previous Match (Shift+Enter)", n == 0)) f.step(ta, true);
        if (iconButton(c, "arrow.down", "Next Match (Enter)", n == 0)) f.step(ta, false);
        if (iconButton(c, "xmark", "Close (Esc)", false)) return ed.closeBars();
    }
    if (!f.replacing) return;
    const row = ui.div(c).row().wFull().pl(22).gap(4).itemsCenter();
    defer row.end();
    const focused = c.focus == ed.replacement_id and ed.replacement_id != 0;
    const frame = ui.div(c).row().grow().h(26).px(8).itemsCenter().rounded(5).bg(editor_bg).border(if (focused) t.accent.alpha(0.7) else t.border);
    const want = ed.focus_next == .replacement;
    if (want) ed.focus_next = .none;
    const r = field(c, &f.replacement, &ed.replacement_id, want, "Replace");
    frame.end();
    if (r.submitted and !ed.read_only) f.replaceOne(ta.doc.gpa, ta);
    if (iconButton(c, "replace", "Replace (Enter)", n == 0 or ed.read_only)) f.replaceOne(ta.doc.gpa, ta);
    if (iconButton(c, "replace_all", "Replace All", n == 0 or ed.read_only)) _ = f.replaceAll(ta.doc.gpa, ta);
    // Under the count and the buttons after it, so that the fields end alike.
    _ = c.leaf(.{ .width = .{ .px = count_w + 3 * 26 + 4 * 4 - (2 * 26 + 3 * 4) } }, .none, null);
}
