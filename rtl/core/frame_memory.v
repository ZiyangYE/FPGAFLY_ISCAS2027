// Arbitrate direct DDR commands and prefetch requests; return responses to their owner.
module frame_memory #(
    parameter PREFETCH=64
) (
    clk, rst, direct_valid, direct_write,
    direct_address, direct_data, stream_start, stream_base,
    stream_lines, stream_take, pixel_mode, pixel_write,
    pixel_write_address, pixel_write_data, pixel_read, pixel_address,
    cmd_ready, wr_ready, rd_valid, rd_data,
    direct_ready, direct_response, stream_valid, stream_data,
    stream_peak, pixel_value, cmd_en, cmd_valid,
    cmd, addr, wr_data, wr_en,
    wr_mask
);
    input clk;
    input rst;
    input direct_valid;
    input direct_write;
    input [31:0] direct_address;
    input [255:0] direct_data;
    input stream_start;
    input [31:0] stream_base;
    input [23:0] stream_lines;
    input stream_take;
    input pixel_mode;
    input pixel_write;
    input [9:0] pixel_write_address;
    input [17:0] pixel_write_data;
    input pixel_read;
    input [9:0] pixel_address;
    input cmd_ready;
    input wr_ready;
    input rd_valid;
    input [255:0] rd_data;
    output direct_ready;
    output direct_response;
    output stream_valid;
    output [255:0] stream_data;
    output [$clog2(PREFETCH):0] stream_peak;
    output [17:0] pixel_value;
    output cmd_en;
    output cmd_valid;
    output [2:0] cmd;
    output [28:0] addr;
    output [255:0] wr_data;
    output wr_en;
    output [31:0] wr_mask;

    wire stream_request, stream_response;
    wire [31:0] stream_address;
    wire input_store = direct_write && direct_address[31:15] == (32'h10990000 >> 15);
    wire input_ready;
    wire direct_issue = direct_valid && direct_ready;
    wire stream_issue = stream_request && !direct_valid && cmd_ready;
    wire read_issue = stream_issue || direct_issue && !direct_write;
    assign direct_ready = input_store ? input_ready : cmd_ready && (!direct_write || wr_ready);
    assign cmd_valid = direct_valid ? !input_store : stream_request;
    assign cmd_en = direct_issue && !input_store || stream_issue;
    assign cmd = direct_valid && direct_write ? 3'b000 : 3'b001;
    wire [31:0] byte_address = direct_valid ? direct_address : stream_address;
    assign addr = {1'b0, byte_address[29:2]};
    assign wr_data = direct_data;
    assign wr_en = direct_issue && direct_write && !input_store;
    assign wr_mask = 0;

    read_tags #(.DEPTH(2*PREFETCH)) tags (
        .clk(clk), .rst(rst), .issue(read_issue), .issue_stream(stream_issue),
        .response_valid(rd_valid), .direct_response(direct_response),
        .stream_response(stream_response)
    );
    wire stream_busy, stream_done;
    memory_reader #(.DEPTH(PREFETCH)) reader (
        clk, rst, stream_start, stream_base, stream_lines, stream_busy, stream_done, stream_request,
        cmd_ready && !direct_valid, stream_address, stream_response, rd_data,
        stream_valid, stream_take, stream_data, stream_peak,
        pixel_mode, pixel_write, pixel_write_address, pixel_write_data,
        pixel_read, pixel_address, pixel_value,
        direct_issue && input_store, direct_address[14:5], direct_data, input_ready
    );
endmodule
