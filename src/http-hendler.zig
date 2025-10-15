const picoRoot = @import("picozig");
const std = @import("std");
const picozig = picoRoot.picozig;
const generateHttpResponse = picoRoot.response.generateHttpResponse;
const HttpRequest = picozig.HttpRequest;

const HttpProcessor = @import("./http-processor.zig").HttpProcessor;
const ProtocolHandler = @import("./types.zig").ProtocolHandler;
const HandlerError = @import("./types.zig").HandlerError;

const block_handlers = @import("./block_handlers.zig");

const RootHandler = struct {
    pub fn handle(request: HttpRequest, allocator: std.mem.Allocator) ![]const u8 {
        _ = request;
        return try generateHttpResponse(
            allocator,
            200,
            "text/plain",
            "FastBlock Storage Server v1.0",
        );
    }
};

var parse_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var process_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var handler_calls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// Глобальный processor (thread-local было бы лучше, но для простоты так)
threadlocal var global_processor: ?HttpProcessor = null;

pub fn httpHandler(allocator: std.mem.Allocator, data: []const u8) anyerror![]const u8 {
    var timer = std.time.Timer.start() catch unreachable;

    var headers: [32]picozig.Header = undefined;
    const httpParams = picozig.HttpParams{
        .method = "",
        .path = "",
        .minor_version = 0,
        .num_headers = 0,
        .bytes_read = 0,
    };

    var httpRequest = picozig.HttpRequest{
        .params = httpParams,
        .headers = &headers,
        .body = "",
    };
    _ = picozig.parseRequest(data, &httpRequest);

    // Извлекаем body (все после заголовков)
    if (httpRequest.params.bytes_read < data.len) {
        // Ищем Content-Length для корректного извлечения body
        var content_length: ?usize = null;
        for (headers[0..httpRequest.params.num_headers]) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Content-Length")) {
                content_length = std.fmt.parseInt(usize, header.value, 10) catch null;
                break;
            }
        }

        const body_start = httpRequest.params.bytes_read;
        if (content_length) |len| {
            const body_end = @min(body_start + len, data.len);
            httpRequest.body = data[body_start..body_end];
        } else {
            httpRequest.body = data[body_start..];
        }
    }

    const parse_elapsed = timer.lap();
    _ = parse_time.fetchAdd(parse_elapsed, .monotonic);

    // Инициализируем processor один раз на поток
    if (global_processor == null) {
        var processor = HttpProcessor.init(allocator);

        // Регистрируем хендлеры (используем новые block_handlers с BlockController)
        try processor.addHandler(.{
            .pathPrefix = "/block",
            .method = "PUT",
            .handleFn = block_handlers.handlePut,
        });
        try processor.addHandler(.{
            .pathPrefix = "/block/",
            .method = "GET",
            .handleFn = block_handlers.handleGet,
        });
        try processor.addHandler(.{
            .pathPrefix = "/block/",
            .method = "DELETE",
            .handleFn = block_handlers.handleDelete,
        });
        try processor.addHandler(.{
            .pathPrefix = "/",
            .method = "GET",
            .handleFn = RootHandler.handle,
        });

        global_processor = processor;
    }

    const response = global_processor.?.processRequest(httpRequest);

    const process_elapsed = timer.read() - parse_elapsed;
    _ = process_time.fetchAdd(process_elapsed, .monotonic);

    const calls = handler_calls.fetchAdd(1, .monotonic) + 1;
    if (calls % 10000 == 0) {
        const avg_parse = parse_time.load(.monotonic) / calls / 1000;
        const avg_process = process_time.load(.monotonic) / calls / 1000;
        std.debug.print("Handler breakdown: parse={d}µs, process={d}µs\n", .{avg_parse, avg_process});
    }

    return response;
}
