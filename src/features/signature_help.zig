const std = @import("std");
const Ast = std.zig.Ast;
const Token = std.zig.Token;

const Analyser = @import("../analysis.zig");
const DocumentStore = @import("../DocumentStore.zig");
const types = @import("../lsp.zig");
const Server = @import("../Server.zig");
const ast = @import("../ast.zig");

const data = @import("../data/data.zig");

fn fnProtoToSignatureInfo(analyser: *Analyser, alloc: std.mem.Allocator, commas: u32, skip_self_param: bool, handle: *const DocumentStore.Handle, fn_node: Ast.Node.Index, proto: Ast.full.FnProto) !types.SignatureInformation {
    const tree = handle.tree;
    const token_starts = tree.tokens.items(.start);
    const label = Analyser.getFunctionSignature(tree, proto);
    const proto_comments = (try Analyser.getDocComments(alloc, tree, fn_node, .markdown)) orelse "";

    const arg_idx = if (skip_self_param) blk: {
        const has_self_param = try analyser.hasSelfParam(handle, proto);
        break :blk commas + @boolToInt(has_self_param);
    } else commas;

    var params = std.ArrayListUnmanaged(types.ParameterInformation){};
    var param_it = proto.iterate(&tree);
    while (ast.nextFnParam(&param_it)) |param| {
        const param_comments = if (param.first_doc_comment) |dc|
            try Analyser.collectDocComments(alloc, tree, dc, .markdown, false)
        else
            "";

        var param_label_start: usize = 0;
        var param_label_end: usize = 0;
        if (param.comptime_noalias) |cn| {
            param_label_start = token_starts[cn];
            param_label_end = param_label_start + tree.tokenSlice(cn).len;
        }
        if (param.name_token) |nt| {
            if (param_label_start == 0)
                param_label_start = token_starts[nt];
            param_label_end = token_starts[nt] + tree.tokenSlice(nt).len;
        }
        if (param.anytype_ellipsis3) |ae| {
            if (param_label_start == 0)
                param_label_start = token_starts[ae];
            param_label_end = token_starts[ae] + tree.tokenSlice(ae).len;
        }
        if (param.type_expr != 0) {
            if (param_label_start == 0)
                param_label_start = token_starts[tree.firstToken(param.type_expr)];

            const last_param_tok = ast.lastToken(tree, param.type_expr);
            param_label_end = token_starts[last_param_tok] + tree.tokenSlice(last_param_tok).len;
        }
        const param_label = tree.source[param_label_start..param_label_end];
        try params.append(alloc, .{
            .label = .{ .string = param_label },
            .documentation = .{ .MarkupContent = .{
                .kind = .markdown,
                .value = param_comments,
            } },
        });
    }
    return types.SignatureInformation{
        .label = label,
        .documentation = .{ .MarkupContent = .{
            .kind = .markdown,
            .value = proto_comments,
        } },
        .parameters = params.items,
        .activeParameter = arg_idx,
    };
}

pub fn getSignatureInfo(analyser: *Analyser, alloc: std.mem.Allocator, handle: *const DocumentStore.Handle, absolute_index: usize) !?types.SignatureInformation {
    const innermost_block = Analyser.innermostBlockScope(handle.*, absolute_index);
    const tree = handle.tree;
    const token_tags = tree.tokens.items(.tag);
    const token_starts = tree.tokens.items(.start);

    // Use the innermost scope to determine the earliest token we would need
    //   to scan up to find a function or builtin call
    const first_token = tree.firstToken(innermost_block);
    // We start by finding the token that includes the current cursor position
    const last_token = blk: {
        if (token_starts[0] >= absolute_index)
            return null;

        var i: u32 = 1;
        while (i < token_tags.len) : (i += 1) {
            if (token_starts[i] >= absolute_index) {
                break :blk i - 1;
            }
        }
        break :blk @truncate(u32, token_tags.len - 1);
    };

    // We scan the tokens from last to first, adding and removing open and close
    //   delimiter tokens to a stack, while keeping track of commas corresponding
    //   to each of the blocks in a stack.
    // When we encounter a dangling left parenthesis token, we continue scanning
    //   backwards for a compatible possible function call lhs expression or a
    //   single builtin token.
    // When a function call expression is detected, it is resolved to a declaration
    //   or a function type and the resulting function prototype is converted into
    //   a signature information object.
    const StackSymbol = enum {
        l_paren,
        r_paren,
        l_brace,
        r_brace,
        l_bracket,
        r_bracket,

        fn from(tag: Token.Tag) @This() {
            return switch (tag) {
                .l_paren => .l_paren,
                .r_paren => .r_paren,
                .l_brace => .l_brace,
                .r_brace => .r_brace,
                .l_bracket => .l_bracket,
                .r_bracket => .r_bracket,
                else => unreachable,
            };
        }
    };
    var symbol_stack = try std.ArrayListUnmanaged(StackSymbol).initCapacity(alloc, 8);
    var curr_commas: u32 = 0;
    var comma_stack = try std.ArrayListUnmanaged(u32).initCapacity(alloc, 4);
    var curr_token = last_token;
    while (curr_token >= first_token and curr_token != 0) : (curr_token -= 1) {
        switch (token_tags[curr_token]) {
            .comma => curr_commas += 1,
            .l_brace => {
                curr_commas = comma_stack.popOrNull() orelse 0;
                if (symbol_stack.items.len != 0) {
                    const peek_sym = symbol_stack.items[symbol_stack.items.len - 1];
                    switch (peek_sym) {
                        .r_brace => {
                            _ = symbol_stack.pop();
                            continue;
                        },
                        .r_bracket, .r_paren => {
                            return null;
                        },
                        else => {},
                    }
                }
                try symbol_stack.append(alloc, .l_brace);
            },
            .l_bracket => {
                curr_commas = comma_stack.popOrNull() orelse 0;
                if (symbol_stack.items.len != 0) {
                    const peek_sym = symbol_stack.items[symbol_stack.items.len - 1];
                    switch (peek_sym) {
                        .r_bracket => {
                            _ = symbol_stack.pop();
                            continue;
                        },
                        .r_brace, .r_paren => {
                            return null;
                        },
                        else => {},
                    }
                }
                try symbol_stack.append(alloc, .l_bracket);
            },
            .l_paren => {
                const paren_commas = curr_commas;
                curr_commas = comma_stack.popOrNull() orelse 0;
                if (symbol_stack.items.len != 0) {
                    const peek_sym = symbol_stack.items[symbol_stack.items.len - 1];
                    switch (peek_sym) {
                        .r_paren => {
                            _ = symbol_stack.pop();
                            continue;
                        },
                        .r_brace, .r_bracket => {
                            return null;
                        },
                        else => {},
                    }
                }

                // Try to find a function expression or a builtin identifier
                if (curr_token == first_token)
                    return null;

                const expr_last_token = curr_token - 1;
                if (token_tags[expr_last_token] == .builtin) {
                    // Builtin token, find the builtin and construct signature information.
                    for (data.builtins) |builtin| {
                        if (std.mem.eql(u8, builtin.name, tree.tokenSlice(expr_last_token))) {
                            const param_infos = try alloc.alloc(
                                types.ParameterInformation,
                                builtin.arguments.len,
                            );
                            for (param_infos, builtin.arguments) |*info, argument| {
                                info.* = .{
                                    .label = .{ .string = argument },
                                    .documentation = null,
                                };
                            }
                            return types.SignatureInformation{
                                .label = builtin.signature,
                                .documentation = .{ .string = builtin.documentation },
                                .parameters = param_infos,
                                .activeParameter = paren_commas,
                            };
                        }
                    }
                    return null;
                }
                // Scan for a function call lhs expression.
                var state: union(enum) {
                    any,
                    in_bracket: u32,
                    in_paren: u32,
                } = .any;
                var i = expr_last_token;
                const expr_first_token = while (i > first_token) : (i -= 1) {
                    switch (state) {
                        .in_bracket => |*count| if (token_tags[i] == .r_bracket) {
                            count.* += 1;
                        } else if (token_tags[i] == .l_bracket) {
                            count.* -= 1;
                            if (count.* == 0)
                                state = .any;
                        },
                        .in_paren => |*count| if (token_tags[i] == .r_paren) {
                            count.* += 1;
                        } else if (token_tags[i] == .l_paren) {
                            count.* -= 1;
                            if (count.* == 0)
                                state = .any;
                        },
                        .any => switch (token_tags[i]) {
                            .r_bracket => state = .{ .in_bracket = 1 },
                            .r_paren => state = .{ .in_paren = 1 },
                            .identifier,
                            .period,
                            .question_mark,
                            .period_asterisk,
                            => {},
                            else => break i + 1,
                        },
                    }
                } else first_token + 1;
                if (state != .any or expr_first_token > expr_last_token) {
                    try symbol_stack.append(alloc, .l_paren);
                    continue;
                }
                const expr_start = token_starts[expr_first_token];
                const last_token_slice = tree.tokenSlice(expr_last_token);
                const expr_end = token_starts[expr_last_token] + last_token_slice.len;

                var held_expr = try alloc.dupeZ(u8, handle.text[expr_start..expr_end]);

                // Resolve the expression.
                var tokenizer = std.zig.Tokenizer.init(held_expr);
                if (try analyser.getFieldAccessType(
                    handle,
                    expr_start,
                    &tokenizer,
                )) |result| {
                    const type_handle = result.unwrapped orelse result.original;
                    var node = switch (type_handle.type.data) {
                        .other => |n| n,
                        else => {
                            try symbol_stack.append(alloc, .l_paren);
                            continue;
                        },
                    };

                    var buf: [1]Ast.Node.Index = undefined;
                    if (type_handle.handle.tree.fullFnProto(&buf, node)) |proto| {
                        return try fnProtoToSignatureInfo(
                            analyser,
                            alloc,
                            paren_commas,
                            false,
                            type_handle.handle,
                            node,
                            proto,
                        );
                    }

                    const name = Server.identifierFromPosition(expr_end - 1, handle.*);
                    if (name.len == 0) {
                        try symbol_stack.append(alloc, .l_paren);
                        continue;
                    }

                    const skip_self_param = !type_handle.type.is_type_val;
                    const decl_handle = (try analyser.lookupSymbolContainer(
                        .{ .node = node, .handle = type_handle.handle },
                        name,
                        true,
                    )) orelse {
                        try symbol_stack.append(alloc, .l_paren);
                        continue;
                    };
                    var res_handle = decl_handle.handle;
                    node = switch (decl_handle.decl.*) {
                        .ast_node => |n| n,
                        else => {
                            try symbol_stack.append(alloc, .l_paren);
                            continue;
                        },
                    };

                    if (try analyser.resolveVarDeclAlias(
                        .{ .node = node, .handle = decl_handle.handle },
                    )) |resolved| {
                        switch (resolved.decl.*) {
                            .ast_node => |n| {
                                res_handle = resolved.handle;
                                node = n;
                            },
                            else => {},
                        }
                    }

                    if (res_handle.tree.fullFnProto(&buf, node)) |proto| {
                        return try fnProtoToSignatureInfo(
                            analyser,
                            alloc,
                            paren_commas,
                            skip_self_param,
                            res_handle,
                            node,
                            proto,
                        );
                    }
                }
            },
            .r_brace, .r_paren, .r_bracket => |tag| {
                try comma_stack.append(alloc, curr_commas);
                curr_commas = 0;
                try symbol_stack.append(alloc, StackSymbol.from(tag));
            },
            else => {},
        }
    }
    return null;
}
