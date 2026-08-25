const r4os = @import("r4os");

const AppApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,

    fn init(r4_app: *r4os.App) ?AppApi {
        return .{
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .draw = r4_app.drawing() orelse return null,
        };
    }
};

const max_tree_items: usize = 32;
const max_values: usize = 16;
const path_max: usize = 128;
const data_max: usize = 64;
const display_max: usize = 96;
const row_h: i32 = 18;
const toolbar_h: i32 = 38;
const status_h: i32 = 22;
const tree_w: i32 = 230;
const button_w: i32 = 82;
const button_h: i32 = 22;
const button_gap: i32 = 6;
const snapshot_depth_max: usize = 4;
const snapshot_restart_max: usize = 3;

const palette = r4os.gui.Palette{
    .text = 0x000000,
    .disabled_text = 0x606060,
    .face = 0xD8D0C8,
    .face_light = 0xFFFFFF,
    .face_shadow = 0x808080,
    .client_bg = 0xFFFFFF,
    .select_bg = 0x0A246A,
    .select_text = 0xFFFFFF,
    .title_bg = 0x0A246A,
    .title_text = 0xFFFFFF,
};

const header_bg: u32 = 0x0A246A;
const header_text: u32 = 0xFFFFFF;
const panel_bg: u32 = 0xFFFFFF;
const bg: u32 = 0xD8D0C8;
const muted: u32 = 0x606060;
const danger: u32 = 0xA00000;
const ok_green: u32 = 0x007020;

const root_count: usize = 1;

const TreeItem = struct {
    path: [path_max]u8 = .{0} ** path_max,
    depth: u8 = 0,
    present: bool = true,

    fn text(self: *const TreeItem) []const u8 {
        return spanZ(self.path[0..]);
    }
};

const ValueRow = struct {
    name: [r4os.abi.registry_name_max]u8 = .{0} ** r4os.abi.registry_name_max,
    value_type: u16 = 0,
    data_len: u32 = 0,
    data: [data_max]u8 = .{0} ** data_max,
    display: [display_max]u8 = .{0} ** display_max,
    large: bool = false,

    fn nameText(self: *const ValueRow) []const u8 {
        const text = spanZ(self.name[0..]);
        return if (text.len == 0) "(Default)" else text;
    }

    fn dataText(self: *const ValueRow) []const u8 {
        return spanZ(self.display[0..]);
    }
};

const Pane = enum {
    tree,
    values,
};

const SnapshotWalkResult = enum {
    complete,
    restart,
    failed,
};

const Action = enum(u8) {
    refresh,
    new_string,
    edit,
    delete,
    new_key,
    rename,
};

const EditMode = enum {
    none,
    new_string,
    edit_value,
};

const EditFocus = enum {
    name,
    data,
    ok,
    cancel,
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var ctx = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    const raw_args = ctx.sys.argsRaw();
    const args = trim(zSlice(raw_args));
    if (argsContain(args, "/SELFTEST") or argsContain(args, "SELFTEST")) return runSelfTest(&ctx);

    return runGui(&ctx);
}

noinline fn runGui(ctx: *AppApi) i32 {
    var app = App{ .ctx = ctx };
    return app.run();
}

const App = struct {
    ctx: *AppApi,
    w: i32 = 760,
    h: i32 = 430,
    should_exit: bool = false,
    pane: Pane = .tree,
    tree: [max_tree_items]TreeItem = .{TreeItem{}} ** max_tree_items,
    tree_count: usize = 0,
    tree_selected: usize = 0,
    tree_first: usize = 0,
    values: [max_values]ValueRow = .{ValueRow{}} ** max_values,
    value_count: usize = 0,
    value_selected: usize = 0,
    value_first: usize = 0,
    pressed_action: ?Action = null,
    edit_mode: EditMode = .none,
    edit_focus: EditFocus = .data,
    edit_type: u16 = r4os.abi.registry_value_type_string,
    edit_name: r4os.gui.TextField(64) = .{},
    edit_data: r4os.gui.TextField(128) = .{},
    status: [160]u8 = .{0} ** 160,
    scratch_paths: [2][path_max]u8 = [_][path_max]u8{.{0} ** path_max} ** 2,
    tree_snapshot_entries: [snapshot_depth_max][r4os.abi.registry_snapshot_page_max]r4os.abi.RegistrySnapshotEntry =
        [_][r4os.abi.registry_snapshot_page_max]r4os.abi.RegistrySnapshotEntry{
            [_]r4os.abi.RegistrySnapshotEntry{.{}} ** r4os.abi.registry_snapshot_page_max,
        } ** snapshot_depth_max,
    value_snapshot_entries: [max_values]r4os.abi.RegistrySnapshotEntry = [_]r4os.abi.RegistrySnapshotEntry{.{}} ** max_values,
    value_snapshot_data: [max_values * data_max]u8 = .{0} ** (max_values * data_max),
    tree_generation: u64 = 0,

    fn run(self: *App) i32 {
        if (self.ctx.desk.programWindowId() >= 0) return self.runHosted();
        self.ctx.sys.println("REGEDIT is a desktop GUI application.");
        self.ctx.sys.println("Please start from Desktop or through GUI launch.");
        return 0;
    }

    fn runHosted(self: *App) i32 {
        _ = self.ctx.desk.guiSetTitle("Registry Editor");
        _ = self.ctx.desk.guiSetMinSize(700, 360);
        self.refreshAll();
        self.updateMetrics();
        self.render();

        while (!self.ctx.sys.programShouldClose() and !self.should_exit) {
            var event: r4os.abi.GuiEvent = .{};
            while (self.ctx.desk.guiPollEvent(&event) > 0) {
                const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
                switch (kind) {
                    .close => return 0,
                    .resize => {
                        self.updateMetrics();
                        self.render();
                    },
                    .mouse_down => self.handleMouseDown(event.x, event.y),
                    .mouse_up => self.handleMouseUp(event.x, event.y),
                    .key_down => self.handleKey(@intCast(event.key & 0xff)),
                    else => {},
                }
            }
            self.ctx.sys.sleepTicks(3);
        }
        return 0;
    }

    fn updateMetrics(self: *App) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        const canvas = r4os.gui.Canvas.init(&self.ctx.draw, info);
        self.w = clampI32(canvas.w, 700, 1600);
        self.h = clampI32(canvas.h, 360, 1000);
    }

    fn refreshAll(self: *App) void {
        self.refreshTree();
        if (self.tree_selected >= self.tree_count) self.tree_selected = if (self.tree_count == 0) 0 else self.tree_count - 1;
        self.refreshValues();
    }

    fn refreshTree(self: *App) void {
        if (self.ctx.sys.hasFn("registry_snapshot_begin") and self.ctx.sys.hasFn("registry_snapshot_page")) {
            var attempt: usize = 0;
            while (attempt < snapshot_restart_max) : (attempt += 1) {
                self.tree_count = 0;
                self.tree_generation = 0;
                var root_index: usize = 0;
                var walk_result: SnapshotWalkResult = .complete;
                while (root_index < root_count) : (root_index += 1) {
                    const root = rootShort(root_index);
                    self.addTreeItem(root, 0, true);
                    walk_result = self.enumerateChildrenSnapshot(root, 1, 0);
                    if (walk_result != .complete) break;
                }
                switch (walk_result) {
                    .complete => {
                        self.setStatus("Ready.");
                        return;
                    },
                    .restart => continue,
                    .failed => {
                        self.setStatus("Registry snapshot failed.");
                        return;
                    },
                }
            }
            self.tree_count = 0;
            self.setStatus("Registry changed repeatedly; refresh again.");
            return;
        }

        self.tree_count = 0;
        var root_index: usize = 0;
        while (root_index < root_count) : (root_index += 1) {
            const root = rootShort(root_index);
            self.addTreeItem(root, 0, true);
            self.enumerateChildren(root, 1, 0);
        }
        self.setStatus("Ready.");
    }

    fn enumerateChildrenSnapshot(self: *App, parent_path: []const u8, depth: u8, level: u8) SnapshotWalkResult {
        if (level >= snapshot_depth_max or self.tree_count >= self.tree.len) return .complete;
        var parent_buf: [path_max]u8 = .{0} ** path_max;
        const parent_z = makeZ(parent_path, parent_buf[0..]) orelse return .failed;
        var cursor: r4os.abi.RegistrySnapshotCursor = .{};
        const begin = self.ctx.sys.registrySnapshotBegin(parent_z, r4os.abi.registry_snapshot_kind_keys, &cursor);
        if (begin == r4os.abi.registry_api_result_hive_not_found) {
            if (self.tree_count > 0 and equalsIgnoreCase(self.tree[self.tree_count - 1].text(), parent_path))
                self.tree[self.tree_count - 1].present = false;
            return .complete;
        }
        if (begin == r4os.abi.registry_api_result_key_not_found) return .complete;
        if (begin != r4os.abi.registry_api_result_ok) return .failed;
        if (self.tree_generation == 0) self.tree_generation = cursor.generation else if (self.tree_generation != cursor.generation) return .restart;

        var unused_data: [1]u8 = .{0};
        while (true) {
            const entries = self.tree_snapshot_entries[level][0..];
            var page: r4os.abi.RegistrySnapshotPageInfo = .{};
            const page_result = self.ctx.sys.registrySnapshotPage(&cursor, entries, unused_data[0..], &page);
            if (page_result != r4os.abi.registry_api_result_ok) return .failed;
            if (page.status == r4os.abi.registry_snapshot_status_restart or page.generation != self.tree_generation) return .restart;
            if (page.status != r4os.abi.registry_snapshot_status_more and page.status != r4os.abi.registry_snapshot_status_complete)
                return .failed;

            const returned: usize = @intCast(page.returned);
            var entry_index: usize = 0;
            while (entry_index < returned and self.tree_count < self.tree.len) : (entry_index += 1) {
                const entry = &entries[entry_index];
                var child_path: [path_max]u8 = .{0} ** path_max;
                const path = joinPath(child_path[0..], parent_path, spanZ(entry.name[0..])) orelse continue;
                self.addTreeItem(path, depth, true);
                const child_result = self.enumerateChildrenSnapshot(path, depth + 1, level + 1);
                if (child_result != .complete) return child_result;
            }
            if (page.status == r4os.abi.registry_snapshot_status_complete or self.tree_count >= self.tree.len) return .complete;
        }
    }

    fn enumerateChildren(self: *App, parent_path: []const u8, depth: u8, level: u8) void {
        if (level >= 4 or self.tree_count >= self.tree.len) return;
        var parent_buf: [path_max]u8 = .{0} ** path_max;
        const parent_z = makeZ(parent_path, parent_buf[0..]) orelse return;
        var key_info: r4os.abi.RegistryKeyInfo = .{};
        const info_result = self.ctx.sys.registryKeyInfo(parent_z, &key_info);
        if (info_result == r4os.abi.registry_api_result_hive_not_found) {
            if (self.tree_count > 0 and equalsIgnoreCase(self.tree[self.tree_count - 1].text(), parent_path)) {
                self.tree[self.tree_count - 1].present = false;
            }
            return;
        }
        if (info_result != r4os.abi.registry_api_result_ok) return;

        var index: u32 = 0;
        while (index < key_info.child_count and self.tree_count < self.tree.len) : (index += 1) {
            var child_name: [r4os.abi.registry_name_max]u8 = .{0} ** r4os.abi.registry_name_max;
            if (self.ctx.sys.registryEnumKey(parent_z, index, child_name[0..]) < 0) continue;
            var child_path: [path_max]u8 = .{0} ** path_max;
            const path = joinPath(child_path[0..], parent_path, spanZ(child_name[0..])) orelse continue;
            self.addTreeItem(path, depth, true);
            self.enumerateChildren(path, depth + 1, level + 1);
        }
    }

    fn addTreeItem(self: *App, path: []const u8, depth: u8, present: bool) void {
        if (self.tree_count >= self.tree.len) return;
        var item = TreeItem{ .depth = depth, .present = present };
        copyZ(item.path[0..], path);
        self.tree[self.tree_count] = item;
        self.tree_count += 1;
    }

    fn refreshValues(self: *App) void {
        if (self.ctx.sys.hasFn("registry_snapshot_begin") and self.ctx.sys.hasFn("registry_snapshot_page")) {
            self.refreshValuesSnapshot();
            return;
        }
        self.refreshValuesLegacy();
    }

    fn refreshValuesSnapshot(self: *App) void {
        var attempt: usize = 0;
        while (attempt < snapshot_restart_max) : (attempt += 1) {
            self.value_count = 0;
            self.value_selected = 0;
            if (self.tree_count == 0) return;
            const path_z = makeZ(self.selectedPath(), self.scratchPath(0)) orelse {
                self.setStatus("Path too long.");
                return;
            };
            var cursor: r4os.abi.RegistrySnapshotCursor = .{};
            const begin = self.ctx.sys.registrySnapshotBegin(path_z, r4os.abi.registry_snapshot_kind_values, &cursor);
            if (begin == r4os.abi.registry_api_result_hive_not_found) {
                self.setStatus("SYSTEM hive missing. Rebuild default registry.");
                return;
            }
            if (begin == r4os.abi.registry_api_result_key_not_found) {
                self.setStatus("Key not found.");
                return;
            }
            if (begin != r4os.abi.registry_api_result_ok) {
                self.setStatus("Registry snapshot failed.");
                return;
            }

            var page: r4os.abi.RegistrySnapshotPageInfo = .{};
            const page_result = self.ctx.sys.registrySnapshotPage(
                &cursor,
                self.value_snapshot_entries[0..],
                self.value_snapshot_data[0..],
                &page,
            );
            if (page_result != r4os.abi.registry_api_result_ok) {
                self.setStatus("Registry snapshot failed.");
                return;
            }
            if (page.status == r4os.abi.registry_snapshot_status_restart) continue;
            if (page.status != r4os.abi.registry_snapshot_status_more and page.status != r4os.abi.registry_snapshot_status_complete) {
                self.setStatus("Registry snapshot invalid.");
                return;
            }

            const returned: usize = @intCast(page.returned);
            const page_data_len: usize = @intCast(page.data_bytes);
            var index: usize = 0;
            while (index < returned and self.value_count < self.values.len) : (index += 1) {
                const entry = &self.value_snapshot_entries[index];
                var row = ValueRow{};
                copyZ(row.name[0..], spanZ(entry.name[0..]));
                row.value_type = entry.value_type;
                row.data_len = entry.data_len;
                const data_offset: usize = @intCast(entry.data_offset);
                const data_len: usize = @intCast(entry.data_len);
                if ((entry.flags & r4os.abi.registry_snapshot_entry_flag_data_present) != 0 and
                    data_len <= row.data.len and data_offset <= page_data_len and data_len <= page_data_len - data_offset)
                {
                    if (data_len != 0) @memcpy(row.data[0..data_len], self.value_snapshot_data[data_offset .. data_offset + data_len]);
                    formatValueDisplay(&row);
                } else if ((entry.flags & r4os.abi.registry_snapshot_entry_flag_data_omitted) != 0 or data_len > row.data.len) {
                    row.large = true;
                    setZ(row.display[0..], "<large>");
                } else {
                    setZ(row.display[0..], "<read failed>");
                }
                self.values[self.value_count] = row;
                self.value_count += 1;
            }
            if (self.value_count == 0) self.setStatus("Key has no values.") else self.setStatus("Ready.");
            return;
        }
        self.value_count = 0;
        self.setStatus("Registry changed repeatedly; refresh again.");
    }

    fn refreshValuesLegacy(self: *App) void {
        self.value_count = 0;
        self.value_selected = 0;
        if (self.tree_count == 0) return;

        const path = self.selectedPath();
        const path_z = makeZ(path, self.scratchPath(0)) orelse {
            self.setStatus("Path too long.");
            return;
        };
        var key_info: r4os.abi.RegistryKeyInfo = .{};
        const info_result = self.ctx.sys.registryKeyInfo(path_z, &key_info);
        if (info_result == r4os.abi.registry_api_result_hive_not_found) {
            self.setStatus("SYSTEM hive missing. Rebuild default registry.");
            return;
        }
        if (info_result == r4os.abi.registry_api_result_key_not_found) {
            self.setStatus("Key not found.");
            return;
        }
        if (info_result != r4os.abi.registry_api_result_ok) {
            self.setStatus("Registry read failed.");
            return;
        }

        var index: u32 = 0;
        while (index < key_info.value_count and self.value_count < self.values.len) : (index += 1) {
            var info: r4os.abi.RegistryValueInfo = .{};
            if (self.ctx.sys.registryEnumValue(path_z, index, &info) != r4os.abi.registry_api_result_ok) continue;
            var row = ValueRow{};
            copyZ(row.name[0..], spanZ(info.name[0..]));
            row.value_type = info.value_type;
            row.data_len = info.data_len;
            const name_z = makeZ(spanZ(row.name[0..]), self.scratchPath(1)) orelse continue;
            var read_info: r4os.abi.RegistryValueInfo = .{};
            const got = self.ctx.sys.registryGetValue(path_z, name_z, &read_info, row.data[0..]);
            if (got >= 0) {
                row.data_len = @intCast(got);
                row.value_type = read_info.value_type;
                formatValueDisplay(&row);
            } else if (got == r4os.abi.registry_api_result_buffer_too_small) {
                row.large = true;
                setZ(row.display[0..], "<large>");
            } else {
                setZ(row.display[0..], "<read failed>");
            }
            self.values[self.value_count] = row;
            self.value_count += 1;
        }

        if (self.value_count == 0) {
            self.setStatus("Key has no values.");
        } else {
            self.setStatus("Ready.");
        }
    }

    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.ctx.draw, self.w, self.h)) {
            .paint => |value| value,
            .failure => return,
        };
        defer paint.discard();
        const canvas = paint.canvas;
        var scratch: [256]u8 = .{0} ** 256;
        _ = canvas.clear(bg);
        self.drawToolbar(canvas, scratch[0..]);
        self.drawTree(canvas, scratch[0..]);
        self.drawValues(canvas, scratch[0..]);
        self.drawStatus(canvas, scratch[0..]);
        if (self.edit_mode != .none) self.drawEditDialog(canvas, scratch[0..]);
        _ = paint.present();
    }

    fn drawToolbar(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        _ = canvas.rect(.{ .x = 0, .y = 0, .w = self.w, .h = toolbar_h }, bg);
        self.drawActionButton(canvas, scratch, .refresh, "Refresh");
        self.drawActionButton(canvas, scratch, .new_string, "New String");
        self.drawActionButton(canvas, scratch, .edit, "Edit");
        self.drawActionButton(canvas, scratch, .delete, "Delete");
        self.drawActionButton(canvas, scratch, .new_key, "New Key");
        self.drawActionButton(canvas, scratch, .rename, "Rename");
    }

    fn drawActionButton(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, action: Action, label: []const u8) void {
        _ = canvas.button(.{
            .rect = self.actionRect(action),
            .text = label,
            .state = if (self.actionDisabled(action)) .disabled else if (self.pressed_action == action) .pressed else .normal,
        }, scratch);
    }

    fn drawTree(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.treeRect();
        self.drawPanel(canvas, rect);
        _ = canvas.rect(self.treeHeaderRect(), header_bg);
        _ = canvas.text(self.treeHeaderRect().x + 6, self.treeHeaderRect().y + 5, "Keys", header_text, header_bg);

        const visible = visibleRows(rect);
        var row: usize = 0;
        while (row < visible and self.tree_first + row < self.tree_count) : (row += 1) {
            const index = self.tree_first + row;
            const item = &self.tree[index];
            const row_rect = self.treeRowRect(row);
            const selected = index == self.tree_selected;
            const row_bg = if (selected) palette.select_bg else panel_bg;
            const fg = if (selected) palette.select_text else if (item.present) palette.text else muted;
            _ = canvas.rect(row_rect, row_bg);
            const indent = row_rect.x + 6 + @as(i32, item.depth) * 12;
            _ = canvas.textClipped(indent, row_rect.y + 4, row_rect.w - (indent - row_rect.x) - 4, scratch, displayPathLeaf(item.text(), item.depth), fg, row_bg);
        }
    }

    fn drawValues(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.valueRect();
        self.drawPanel(canvas, rect);
        const header = self.valueHeaderRect();
        _ = canvas.rect(header, header_bg);
        _ = canvas.text(header.x + 6, header.y + 5, "Name", header_text, header_bg);
        _ = canvas.text(header.x + 178, header.y + 5, "Type", header_text, header_bg);
        _ = canvas.text(header.x + 260, header.y + 5, "Data", header_text, header_bg);

        const visible = visibleRows(rect);
        var row: usize = 0;
        while (row < visible and self.value_first + row < self.value_count) : (row += 1) {
            const index = self.value_first + row;
            const value = &self.values[index];
            const row_rect = self.valueRowRect(row);
            const selected = index == self.value_selected and self.pane == .values;
            const row_bg = if (selected) palette.select_bg else panel_bg;
            const fg = if (selected) palette.select_text else palette.text;
            _ = canvas.rect(row_rect, row_bg);
            _ = canvas.textClipped(row_rect.x + 6, row_rect.y + 4, 166, scratch, value.nameText(), fg, row_bg);
            _ = canvas.textClipped(row_rect.x + 178, row_rect.y + 4, 76, scratch, valueTypeName(value.value_type), fg, row_bg);
            _ = canvas.textClipped(row_rect.x + 260, row_rect.y + 4, row_rect.w - 266, scratch, value.dataText(), fg, row_bg);
        }
    }

    fn drawPanel(self: *App, canvas: r4os.gui.Canvas, rect: r4os.gui.Rect) void {
        _ = self;
        _ = canvas.rect(rect, palette.face_shadow);
        _ = canvas.rect(.{ .x = rect.x + 1, .y = rect.y + 1, .w = @max(0, rect.w - 2), .h = @max(0, rect.h - 2) }, panel_bg);
    }

    fn drawStatus(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.statusRect();
        _ = canvas.rect(rect, bg);
        const path = self.selectedPath();
        _ = canvas.textClipped(rect.x + 6, rect.y + 5, 260, scratch, path, palette.text, bg);
        _ = canvas.textClipped(rect.x + 274, rect.y + 5, rect.w - 280, scratch, spanZ(self.status[0..]), muted, bg);
    }

    fn drawEditDialog(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.editRect();
        _ = canvas.rect(.{ .x = 0, .y = 0, .w = self.w, .h = self.h }, 0x808080);
        _ = r4os.gui.drawDialogFrame(canvas, rect, scratch, if (self.edit_mode == .new_string) "New String Value" else "Edit Value", palette);
        _ = canvas.text(rect.x + 16, rect.y + 40, "Name:", palette.text, bg);
        _ = self.edit_name.draw(canvas, self.editNameRect(), scratch);
        _ = canvas.text(rect.x + 16, rect.y + 76, "Type:", palette.text, bg);
        _ = canvas.textClipped(rect.x + 96, rect.y + 76, rect.w - 112, scratch, valueTypeName(self.edit_type), palette.text, bg);
        _ = canvas.text(rect.x + 16, rect.y + 112, "Data:", palette.text, bg);
        _ = self.edit_data.draw(canvas, self.editDataRect(), scratch);
        _ = canvas.button(.{
            .rect = self.editOkRect(),
            .text = "OK",
            .state = if (self.edit_focus == .ok and self.pressed_action == null) .normal else .normal,
            .focused = self.edit_focus == .ok,
            .is_default = true,
        }, scratch);
        _ = canvas.button(.{
            .rect = self.editCancelRect(),
            .text = "Cancel",
            .focused = self.edit_focus == .cancel,
            .is_cancel = true,
        }, scratch);
    }

    fn handleMouseDown(self: *App, x: i32, y: i32) void {
        self.pressed_action = null;
        if (self.edit_mode != .none) {
            self.handleEditMouseDown(x, y);
            self.render();
            return;
        }

        if (self.actionAt(x, y)) |action| {
            if (!self.actionDisabled(action)) self.pressed_action = action;
            self.render();
            return;
        }

        if (self.treeIndexAt(x, y)) |index| {
            self.pane = .tree;
            self.tree_selected = index;
            self.refreshValues();
            self.render();
            return;
        }

        if (self.valueIndexAt(x, y)) |index| {
            self.pane = .values;
            self.value_selected = index;
            self.render();
            return;
        }
    }

    fn handleMouseUp(self: *App, x: i32, y: i32) void {
        if (self.edit_mode != .none) {
            self.handleEditMouseUp(x, y);
            self.render();
            return;
        }
        const pressed = self.pressed_action orelse return;
        self.pressed_action = null;
        if (self.actionAt(x, y)) |action| {
            if (action == pressed) self.runAction(action);
        }
        self.render();
    }

    fn handleKey(self: *App, key: u8) void {
        if (self.edit_mode != .none) {
            if (self.handleEditKey(key)) self.render();
            return;
        }

        switch (key) {
            r4os.gui.Key.escape => self.should_exit = true,
            r4os.gui.Key.tab => self.pane = if (self.pane == .tree) .values else .tree,
            r4os.gui.Key.up => self.moveSelection(-1),
            r4os.gui.Key.down => self.moveSelection(1),
            r4os.gui.Key.enter => if (self.pane == .values) self.openEditSelected(),
            r4os.gui.Key.delete => self.deleteSelectedValue(),
            'r', 'R' => self.refreshAll(),
            'n', 'N' => self.openNewString(),
            'e', 'E' => self.openEditSelected(),
            else => {},
        }
        self.ensureVisible();
        self.render();
    }

    fn handleEditMouseDown(self: *App, x: i32, y: i32) void {
        if (self.editNameRect().contains(x, y) and !self.edit_name.disabled) {
            self.setEditFocus(.name);
        } else if (self.editDataRect().contains(x, y)) {
            self.setEditFocus(.data);
        } else if (self.editOkRect().contains(x, y)) {
            self.edit_focus = .ok;
        } else if (self.editCancelRect().contains(x, y)) {
            self.edit_focus = .cancel;
        }
    }

    fn handleEditMouseUp(self: *App, x: i32, y: i32) void {
        if (self.editOkRect().contains(x, y)) {
            self.saveEdit();
        } else if (self.editCancelRect().contains(x, y)) {
            self.closeEdit();
        }
    }

    fn handleEditKey(self: *App, key: u8) bool {
        switch (key) {
            r4os.gui.Key.escape => {
                self.closeEdit();
                return true;
            },
            r4os.gui.Key.tab => {
                self.nextEditFocus();
                return true;
            },
            r4os.gui.Key.enter => {
                if (self.edit_focus == .cancel) self.closeEdit() else self.saveEdit();
                return true;
            },
            else => {},
        }
        return switch (self.edit_focus) {
            .name => self.edit_name.handleClipboardKey(&self.ctx.desk, key),
            .data => self.edit_data.handleClipboardKey(&self.ctx.desk, key),
            .ok, .cancel => false,
        };
    }

    fn moveSelection(self: *App, delta: i32) void {
        if (self.pane == .tree) {
            self.tree_selected = moveIndex(self.tree_selected, self.tree_count, delta);
            self.refreshValues();
        } else {
            self.value_selected = moveIndex(self.value_selected, self.value_count, delta);
        }
    }

    fn openNewString(self: *App) void {
        if (self.tree_count == 0) return;
        self.edit_mode = .new_string;
        self.edit_type = r4os.abi.registry_value_type_string;
        self.edit_name.disabled = false;
        self.edit_name.set("NewValue");
        self.edit_name.selectAll();
        self.edit_data.set("");
        self.setEditFocus(.name);
    }

    fn openEditSelected(self: *App) void {
        if (self.value_count == 0 or self.value_selected >= self.value_count) return;
        const value = &self.values[self.value_selected];
        if (!editableType(value.value_type) or value.large) {
            self.setStatus("Only string, u32, u64 and bool values are editable here.");
            return;
        }
        self.edit_mode = .edit_value;
        self.edit_type = value.value_type;
        self.edit_name.disabled = true;
        self.edit_name.set(spanZ(value.name[0..]));
        self.edit_data.set(value.dataText());
        self.edit_data.selectAll();
        self.setEditFocus(.data);
    }

    fn saveEdit(self: *App) void {
        const name = trim(self.edit_name.value());
        if (!validValueName(name)) {
            self.setStatus("Invalid value name.");
            return;
        }
        const key_path = makeZ(self.selectedPath(), self.scratchPath(0)) orelse {
            self.setStatus("Path too long.");
            return;
        };
        const value_name = makeZ(name, self.scratchPath(1)) orelse {
            self.setStatus("Value name too long.");
            return;
        };
        const data = trim(self.edit_data.value());
        const result = switch (self.edit_type) {
            r4os.abi.registry_value_type_string => self.ctx.sys.registrySetString(key_path, value_name, data),
            r4os.abi.registry_value_type_u32 => blk: {
                const parsed = parseUnsigned(data, 0xffff_ffff) orelse {
                    self.setStatus("Invalid u32 data.");
                    return;
                };
                break :blk self.ctx.sys.registrySetU32(key_path, value_name, @intCast(parsed));
            },
            r4os.abi.registry_value_type_u64 => blk: {
                const parsed = parseUnsigned(data, 0xffff_ffff_ffff_ffff) orelse {
                    self.setStatus("Invalid u64 data.");
                    return;
                };
                break :blk self.ctx.sys.registrySetU64(key_path, value_name, parsed);
            },
            r4os.abi.registry_value_type_bool => blk: {
                const parsed = parseBool(data) orelse {
                    self.setStatus("Invalid bool data.");
                    return;
                };
                break :blk self.ctx.sys.registrySetBool(key_path, value_name, parsed);
            },
            else => r4os.abi.registry_api_result_unsupported,
        };
        if (result != r4os.abi.registry_api_result_ok) {
            self.setStatus("Registry write failed.");
            return;
        }
        self.closeEdit();
        self.refreshAll();
        self.pane = .values;
        self.setStatus("Value saved.");
    }

    fn closeEdit(self: *App) void {
        self.edit_mode = .none;
        self.edit_name.disabled = false;
        self.edit_name.focused = false;
        self.edit_data.focused = false;
    }

    fn deleteSelectedValue(self: *App) void {
        if (self.value_count == 0 or self.value_selected >= self.value_count) return;
        const key_path = makeZ(self.selectedPath(), self.scratchPath(0)) orelse {
            self.setStatus("Path too long.");
            return;
        };
        const name = spanZ(self.values[self.value_selected].name[0..]);
        const value_name = makeZ(name, self.scratchPath(1)) orelse {
            self.setStatus("Value name too long.");
            return;
        };
        const result = self.ctx.sys.registryDeleteValue(key_path, value_name);
        if (result != r4os.abi.registry_api_result_ok) {
            self.setStatus("Delete failed.");
            return;
        }
        self.refreshAll();
        self.pane = .values;
        self.setStatus("Value deleted.");
    }

    fn runAction(self: *App, action: Action) void {
        switch (action) {
            .refresh => self.refreshAll(),
            .new_string => self.openNewString(),
            .edit => self.openEditSelected(),
            .delete => self.deleteSelectedValue(),
            .new_key => self.setStatus("New Key needs a future key-create API."),
            .rename => self.setStatus("Rename needs a future key/value rename API."),
        }
    }

    fn actionDisabled(self: *const App, action: Action) bool {
        return switch (action) {
            .edit, .delete => self.value_count == 0,
            .new_key, .rename => true,
            else => false,
        };
    }

    fn selectedPath(self: *const App) []const u8 {
        if (self.tree_count == 0 or self.tree_selected >= self.tree_count) return "SYSTEM";
        return self.tree[self.tree_selected].text();
    }

    fn setStatus(self: *App, text: []const u8) void {
        copyZ(self.status[0..], text);
    }

    fn setEditFocus(self: *App, focus: EditFocus) void {
        self.edit_focus = focus;
        self.edit_name.focused = focus == .name;
        self.edit_data.focused = focus == .data;
    }

    fn nextEditFocus(self: *App) void {
        const next = switch (self.edit_focus) {
            .name => .data,
            .data => .ok,
            .ok => .cancel,
            .cancel => if (self.edit_name.disabled) EditFocus.data else EditFocus.name,
        };
        self.setEditFocus(next);
    }

    fn ensureVisible(self: *App) void {
        self.tree_first = firstForSelection(self.tree_count, visibleRows(self.treeRect()), self.tree_selected, self.tree_first);
        self.value_first = firstForSelection(self.value_count, visibleRows(self.valueRect()), self.value_selected, self.value_first);
    }

    fn actionAt(self: *const App, x: i32, y: i32) ?Action {
        const actions = [_]Action{ .refresh, .new_string, .edit, .delete, .new_key, .rename };
        for (actions) |action| {
            if (self.actionRect(action).contains(x, y)) return action;
        }
        return null;
    }

    fn treeIndexAt(self: *const App, x: i32, y: i32) ?usize {
        const body = self.treeBodyRect();
        if (!body.contains(x, y)) return null;
        const row: usize = @intCast(@divTrunc(y - body.y, row_h));
        const index = self.tree_first + row;
        return if (index < self.tree_count) index else null;
    }

    fn valueIndexAt(self: *const App, x: i32, y: i32) ?usize {
        const body = self.valueBodyRect();
        if (!body.contains(x, y)) return null;
        const row: usize = @intCast(@divTrunc(y - body.y, row_h));
        const index = self.value_first + row;
        return if (index < self.value_count) index else null;
    }

    fn actionRect(self: *const App, action: Action) r4os.gui.Rect {
        _ = self;
        const index: i32 = switch (action) {
            .refresh => 0,
            .new_string => 1,
            .edit => 2,
            .delete => 3,
            .new_key => 4,
            .rename => 5,
        };
        const width = if (action == .new_string) 96 else button_w;
        var x: i32 = 8;
        var i: i32 = 0;
        while (i < index) : (i += 1) x += if (i == 1) 96 + button_gap else button_w + button_gap;
        return .{ .x = x, .y = 8, .w = width, .h = button_h };
    }

    fn treeRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 8, .y = toolbar_h, .w = tree_w, .h = self.h - toolbar_h - status_h - 8 };
    }

    fn valueRect(self: *const App) r4os.gui.Rect {
        return .{ .x = tree_w + 16, .y = toolbar_h, .w = self.w - tree_w - 24, .h = self.h - toolbar_h - status_h - 8 };
    }

    fn treeHeaderRect(self: *const App) r4os.gui.Rect {
        const rect = self.treeRect();
        return .{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = row_h };
    }

    fn treeBodyRect(self: *const App) r4os.gui.Rect {
        const rect = self.treeRect();
        return .{ .x = rect.x + 1, .y = rect.y + 1 + row_h, .w = rect.w - 2, .h = rect.h - 2 - row_h };
    }

    fn treeRowRect(self: *const App, row: usize) r4os.gui.Rect {
        const body = self.treeBodyRect();
        return .{ .x = body.x, .y = body.y + @as(i32, @intCast(row)) * row_h, .w = body.w, .h = row_h };
    }

    fn valueHeaderRect(self: *const App) r4os.gui.Rect {
        const rect = self.valueRect();
        return .{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = row_h };
    }

    fn valueBodyRect(self: *const App) r4os.gui.Rect {
        const rect = self.valueRect();
        return .{ .x = rect.x + 1, .y = rect.y + 1 + row_h, .w = rect.w - 2, .h = rect.h - 2 - row_h };
    }

    fn valueRowRect(self: *const App, row: usize) r4os.gui.Rect {
        const body = self.valueBodyRect();
        return .{ .x = body.x, .y = body.y + @as(i32, @intCast(row)) * row_h, .w = body.w, .h = row_h };
    }

    fn statusRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 0, .y = self.h - status_h, .w = self.w, .h = status_h };
    }

    fn editRect(self: *const App) r4os.gui.Rect {
        const w = @min(440, self.w - 40);
        const h = 190;
        return .{ .x = @divTrunc(self.w - w, 2), .y = @divTrunc(self.h - h, 2), .w = w, .h = h };
    }

    fn editNameRect(self: *const App) r4os.gui.Rect {
        const rect = self.editRect();
        return .{ .x = rect.x + 96, .y = rect.y + 35, .w = rect.w - 112, .h = 22 };
    }

    fn editDataRect(self: *const App) r4os.gui.Rect {
        const rect = self.editRect();
        return .{ .x = rect.x + 96, .y = rect.y + 107, .w = rect.w - 112, .h = 22 };
    }

    fn editOkRect(self: *const App) r4os.gui.Rect {
        const rect = self.editRect();
        return .{ .x = rect.x + rect.w - 164, .y = rect.y + rect.h - 36, .w = 72, .h = 24 };
    }

    fn editCancelRect(self: *const App) r4os.gui.Rect {
        const rect = self.editRect();
        return .{ .x = rect.x + rect.w - 84, .y = rect.y + rect.h - 36, .w = 72, .h = 24 };
    }

    fn scratchPath(self: *App, index: usize) []u8 {
        return self.scratch_paths[index][0..];
    }
};

noinline fn runSelfTest(ctx: *AppApi) i32 {
    if (!ctx.sys.hasFn("registry_get_value") or !ctx.sys.hasFn("registry_set_value")) return selfTestFail(ctx, "api-missing");
    if (!ctx.sys.hasFn("registry_snapshot_begin") or !ctx.sys.hasFn("registry_snapshot_page") or !ctx.sys.hasFn("registry_batch_mutate"))
        return selfTestFail(ctx, "snapshot-batch-api-missing");

    var system_hive_buf: [path_max]u8 = .{0} ** path_max;
    var system_tmp_buf: [path_max]u8 = .{0} ** path_max;
    var system_bak_buf: [path_max]u8 = .{0} ** path_max;
    var regedit_bak_buf: [path_max]u8 = .{0} ** path_max;
    const system_hive = literalZ("C:\\R4OS\\REGISTRY\\SYSTEM.R4R", system_hive_buf[0..]) orelse return selfTestFail(ctx, "path-too-long");
    const system_tmp = literalZ("C:\\R4OS\\REGISTRY\\SYSTEM.TMP", system_tmp_buf[0..]) orelse return selfTestFail(ctx, "path-too-long");
    const system_bak = literalZ("C:\\R4OS\\REGISTRY\\SYSTEM.BAK", system_bak_buf[0..]) orelse return selfTestFail(ctx, "path-too-long");
    const regedit_bak = literalZ("C:\\R4OS\\REGISTRY\\SYSTEM.REB", regedit_bak_buf[0..]) orelse return selfTestFail(ctx, "path-too-long");
    const had_system = ctx.sys.exists(system_hive);
    _ = ctx.sys.fileDelete(regedit_bak);
    if (had_system and ctx.sys.fileCopy(system_hive, regedit_bak) <= 0) return selfTestFail(ctx, "backup-failed");

    const facade_key = r4os.RegistryPath.parse("SYSTEM\\RegeditSelftest") catch return restoreSelfTest(ctx, had_system, "path-too-long");
    var operation_storage: [3]r4os.abi.RegistryBatchOperation = undefined;
    var blob_storage: [256]u8 = undefined;
    var builder = r4os.RegistryBatchBuilder.init(operation_storage[0..], blob_storage[0..]);
    builder.setString(&facade_key, "Name", "Regedit") catch return restoreSelfTest(ctx, had_system, "batch-build-string");
    builder.setU32(&facade_key, "Count", 46) catch return restoreSelfTest(ctx, had_system, "batch-build-u32");
    builder.setBool(&facade_key, "Flag", true) catch return restoreSelfTest(ctx, had_system, "batch-build-bool");
    const registry_api = r4os.Registry{ .sys = ctx.sys };
    if (!registry_api.applyBatch(&builder).committed()) return restoreSelfTest(ctx, had_system, "batch-seed");

    const model_error = selfTestModel(ctx);
    if (model_error.len != 0) return restoreSelfTest(ctx, had_system, model_error);

    builder.reset();
    builder.delete(&facade_key, "Name") catch return restoreSelfTest(ctx, had_system, "batch-delete-string");
    builder.delete(&facade_key, "Count") catch return restoreSelfTest(ctx, had_system, "batch-delete-u32");
    builder.delete(&facade_key, "Flag") catch return restoreSelfTest(ctx, had_system, "batch-delete-bool");
    if (!registry_api.applyBatch(&builder).committed()) return restoreSelfTest(ctx, had_system, "batch-cleanup");

    if (had_system) {
        _ = ctx.sys.fileDelete(system_hive);
        _ = ctx.sys.fileCopy(regedit_bak, system_hive);
    } else {
        _ = ctx.sys.fileDelete(system_hive);
        _ = ctx.sys.fileDelete(system_tmp);
        _ = ctx.sys.fileDelete(system_bak);
    }
    _ = ctx.sys.fileDelete(regedit_bak);
    ctx.sys.println("REGEDIT snapshot batch selftest: OK");
    ctx.sys.println("REGEDIT selftest: OK");
    return 0;
}

noinline fn selfTestModel(ctx: *AppApi) []const u8 {
    var app = App{ .ctx = ctx };
    app.refreshAll();
    if (!selectTreePath(&app, "SYSTEM\\RegeditSelftest")) return "select-key";
    app.refreshValues();
    if (!findValue(&app, "Name", r4os.abi.registry_value_type_string, "Regedit")) return "read-string";
    if (!findValue(&app, "Count", r4os.abi.registry_value_type_u32, "46")) return "read-u32";
    if (!findValue(&app, "Flag", r4os.abi.registry_value_type_bool, "true")) return "read-bool";
    return "";
}

fn restoreSelfTest(ctx: *AppApi, had_system: bool, text: []const u8) i32 {
    var system_hive_buf: [path_max]u8 = .{0} ** path_max;
    var system_tmp_buf: [path_max]u8 = .{0} ** path_max;
    var system_bak_buf: [path_max]u8 = .{0} ** path_max;
    var regedit_bak_buf: [path_max]u8 = .{0} ** path_max;
    const system_hive = literalZ("C:\\R4OS\\REGISTRY\\SYSTEM.R4R", system_hive_buf[0..]) orelse return selfTestFail(ctx, text);
    const system_tmp = literalZ("C:\\R4OS\\REGISTRY\\SYSTEM.TMP", system_tmp_buf[0..]) orelse return selfTestFail(ctx, text);
    const system_bak = literalZ("C:\\R4OS\\REGISTRY\\SYSTEM.BAK", system_bak_buf[0..]) orelse return selfTestFail(ctx, text);
    const regedit_bak = literalZ("C:\\R4OS\\REGISTRY\\SYSTEM.REB", regedit_bak_buf[0..]) orelse return selfTestFail(ctx, text);
    if (had_system) {
        _ = ctx.sys.fileDelete(system_hive);
        _ = ctx.sys.fileCopy(regedit_bak, system_hive);
    } else {
        _ = ctx.sys.fileDelete(system_hive);
        _ = ctx.sys.fileDelete(system_tmp);
        _ = ctx.sys.fileDelete(system_bak);
    }
    _ = ctx.sys.fileDelete(regedit_bak);
    return selfTestFail(ctx, text);
}

fn selfTestFail(ctx: *AppApi, text: []const u8) i32 {
    ctx.sys.write("REGEDIT selftest failed: ");
    ctx.sys.println(text);
    return 1;
}

fn selectTreePath(app: *App, path: []const u8) bool {
    var index: usize = 0;
    while (index < app.tree_count) : (index += 1) {
        if (equalsIgnoreCase(app.tree[index].text(), path)) {
            app.tree_selected = index;
            return true;
        }
    }
    return false;
}

fn findValue(app: *const App, name: []const u8, value_type: u16, display: []const u8) bool {
    var index: usize = 0;
    while (index < app.value_count) : (index += 1) {
        const row = &app.values[index];
        if (equalsIgnoreCase(spanZ(row.name[0..]), name) and row.value_type == value_type and equalsIgnoreCase(row.dataText(), display)) return true;
    }
    return false;
}

fn formatValueDisplay(row: *ValueRow) void {
    clearZ(row.display[0..]);
    const data = row.data[0..@min(@as(usize, @intCast(row.data_len)), row.data.len)];
    switch (row.value_type) {
        r4os.abi.registry_value_type_string => copyZ(row.display[0..], data),
        r4os.abi.registry_value_type_u32 => if (data.len == 4) writeDec(row.display[0..], readU32(data, 0)) else setZ(row.display[0..], "<bad u32>"),
        r4os.abi.registry_value_type_u64 => if (data.len == 8) writeDec(row.display[0..], readU64(data, 0)) else setZ(row.display[0..], "<bad u64>"),
        r4os.abi.registry_value_type_bool => if (data.len == 1) setZ(row.display[0..], if (data[0] != 0) "true" else "false") else setZ(row.display[0..], "<bad bool>"),
        r4os.abi.registry_value_type_binary => formatBinary(row.display[0..], data),
        r4os.abi.registry_value_type_multi_string => {
            setZ(row.display[0..], "<multi_string ");
            appendDec(row.display[0..], data.len);
            appendZ(row.display[0..], " bytes>");
        },
        else => setZ(row.display[0..], "<unknown>"),
    }
}

fn formatBinary(out: []u8, data: []const u8) void {
    clearZ(out);
    const count = @min(data.len, 24);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (index != 0) appendZ(out, " ");
        appendHexByte(out, data[index]);
    }
    if (data.len > count) appendZ(out, " ...");
}

fn editableType(value_type: u16) bool {
    return value_type == r4os.abi.registry_value_type_string or
        value_type == r4os.abi.registry_value_type_u32 or
        value_type == r4os.abi.registry_value_type_u64 or
        value_type == r4os.abi.registry_value_type_bool;
}

fn valueTypeName(value_type: u16) []const u8 {
    return switch (value_type) {
        r4os.abi.registry_value_type_string => "string",
        r4os.abi.registry_value_type_u32 => "u32",
        r4os.abi.registry_value_type_u64 => "u64",
        r4os.abi.registry_value_type_bool => "bool",
        r4os.abi.registry_value_type_binary => "binary",
        r4os.abi.registry_value_type_multi_string => "multi_string",
        else => "unknown",
    };
}

fn displayPathLeaf(path: []const u8, depth: u8) []const u8 {
    if (depth == 0) {
        return rootTitle(path);
    }
    var last: usize = 0;
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '\\' or path[index] == '/') last = index + 1;
    }
    return path[last..];
}

fn rootShort(index: usize) []const u8 {
    return switch (index) {
        0 => "SYSTEM",
        else => "",
    };
}

fn rootTitle(path: []const u8) []const u8 {
    if (equalsIgnoreCase(path, "SYSTEM")) return "SYSTEM";
    return path;
}

fn visibleRows(rect: r4os.gui.Rect) usize {
    if (rect.h <= row_h * 2) return 0;
    return @intCast(@divTrunc(rect.h - row_h - 2, row_h));
}

fn moveIndex(current: usize, count: usize, delta: i32) usize {
    if (count == 0) return 0;
    if (delta < 0) return if (current == 0) 0 else current - 1;
    if (delta > 0) return if (current + 1 >= count) count - 1 else current + 1;
    return current;
}

fn firstForSelection(count: usize, visible: usize, selected: usize, current: usize) usize {
    if (count == 0 or visible == 0 or count <= visible) return 0;
    var first = @min(current, count - visible);
    if (selected < first) first = selected;
    if (selected >= first + visible) first = selected - visible + 1;
    return @min(first, count - visible);
}

fn validValueName(name: []const u8) bool {
    if (name.len > 63) return false;
    for (name) |ch| {
        if (ch < 0x20 or ch == 0x7f or ch == 0 or ch == '\\' or ch == '/' or ch == '=') return false;
    }
    return true;
}

fn parseUnsigned(text_raw: []const u8, max_value: u64) ?u64 {
    var text = trim(text_raw);
    if (text.len == 0) return null;
    var base: u64 = 10;
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        text = text[2..];
        base = 16;
        if (text.len == 0) return null;
    }
    var value: u64 = 0;
    for (text) |ch| {
        const digit = if (base == 16) hexNibble(ch) orelse return null else decimalDigit(ch) orelse return null;
        if (value > (max_value - digit) / base) return null;
        value = value * base + digit;
    }
    return value;
}

fn parseBool(text: []const u8) ?bool {
    const value = trim(text);
    if (equalsIgnoreCase(value, "true") or equalsIgnoreCase(value, "on") or equalsIgnoreCase(value, "yes") or equalsIgnoreCase(value, "1")) return true;
    if (equalsIgnoreCase(value, "false") or equalsIgnoreCase(value, "off") or equalsIgnoreCase(value, "no") or equalsIgnoreCase(value, "0")) return false;
    return null;
}

fn joinPath(out: []u8, parent: []const u8, child: []const u8) ?[]const u8 {
    if (parent.len + 1 + child.len + 1 > out.len) return null;
    @memcpy(out[0..parent.len], parent);
    out[parent.len] = '\\';
    @memcpy(out[parent.len + 1 .. parent.len + 1 + child.len], child);
    out[parent.len + 1 + child.len] = 0;
    return out[0 .. parent.len + 1 + child.len];
}

fn clampI32(value: i32, min_value: i32, max_value: i32) i32 {
    return @min(@max(value, min_value), max_value);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

fn readU64(data: []const u8, offset: usize) u64 {
    return @as(u64, readU32(data, offset)) | (@as(u64, readU32(data, offset + 4)) << 32);
}

fn writeDec(out: []u8, value: u64) void {
    clearZ(out);
    appendDec(out, value);
}

fn appendDec(out: []u8, value: u64) void {
    var buf: [20]u8 = undefined;
    var pos = buf.len;
    var n = value;
    if (n == 0) {
        appendByteZ(out, '0');
        return;
    }
    while (n > 0) {
        pos -= 1;
        buf[pos] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    appendZ(out, buf[pos..]);
}

fn appendHexByte(out: []u8, value: u8) void {
    const digits = "0123456789ABCDEF";
    appendByteZ(out, digits[value >> 4]);
    appendByteZ(out, digits[value & 0x0f]);
}

fn decimalDigit(ch: u8) ?u64 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    return null;
}

fn hexNibble(ch: u8) ?u64 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

fn argsContain(args_raw: []const u8, needle: []const u8) bool {
    var rest = args_raw;
    while (takeToken(rest)) |part| {
        if (equalsIgnoreCase(part.token, needle)) return true;
        rest = part.rest;
    }
    return false;
}

const Token = struct {
    token: []const u8,
    rest: []const u8,
};

fn takeToken(text_raw: []const u8) ?Token {
    const text = trim(text_raw);
    if (text.len == 0) return null;
    var index: usize = 0;
    while (index < text.len and !isSpace(text[index])) : (index += 1) {}
    return .{ .token = text[0..index], .rest = text[index..] };
}

fn zSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn spanZ(bytes: []const u8) []const u8 {
    var len: usize = 0;
    while (len < bytes.len and bytes[len] != 0) : (len += 1) {}
    return bytes[0..len];
}

fn makeZ(text: []const u8, out: []u8) ?[*:0]const u8 {
    if (text.len + 1 > out.len) return null;
    if (text.len != 0) @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return @ptrCast(out.ptr);
}

fn literalZ(comptime text: []const u8, out: []u8) ?[*:0]const u8 {
    if (text.len + 1 > out.len) return null;
    inline for (text, 0..) |ch, index| out[index] = ch;
    out[text.len] = 0;
    return @ptrCast(out.ptr);
}

fn copyZ(out: []u8, text: []const u8) void {
    clearZ(out);
    const len = @min(text.len, out.len - 1);
    if (len != 0) @memcpy(out[0..len], text[0..len]);
    out[len] = 0;
}

fn setZ(out: []u8, text: []const u8) void {
    copyZ(out, text);
}

fn appendZ(out: []u8, text: []const u8) void {
    var len = spanZ(out).len;
    var index: usize = 0;
    while (index < text.len and len + 1 < out.len) : (index += 1) {
        out[len] = text[index];
        len += 1;
    }
    if (out.len != 0) out[len] = 0;
}

fn appendByteZ(out: []u8, ch: u8) void {
    var len = spanZ(out).len;
    if (len + 1 >= out.len) return;
    out[len] = ch;
    len += 1;
    out[len] = 0;
}

fn clearZ(out: []u8) void {
    if (out.len != 0) @memset(out, 0);
}

fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and isSpace(text[start])) : (start += 1) {}
    while (end > start and isSpace(text[end - 1])) : (end -= 1) {}
    return text[start..end];
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (asciiUpper(a[index]) != asciiUpper(b[index])) return false;
    }
    return true;
}

fn asciiUpper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}
