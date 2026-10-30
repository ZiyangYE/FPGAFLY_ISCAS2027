module host_bridge (
    input wire board_clk,
    input wire clk,
    input wire rst,
    input wire calibrated,
    input wire tck,
    input wire tms,
    input wire tdi,
    output wire tdo,
    output wire busy,
    output wire core_request,
    output wire [511:0] core_packet,
    input wire core_ack,
    input wire [511:0] core_response,
    input wire core_valid,
    output wire core_ready,
    input wire [2:0] core_command,
    input wire [28:0] core_address,
    input wire [255:0] core_data,
    input wire [31:0] core_mask,
    output wire core_read_valid,
    output wire memory_valid,
    input wire memory_ready,
    output wire [2:0] memory_command,
    output wire [28:0] memory_address,
    output wire [255:0] memory_data,
    output wire [31:0] memory_mask,
    input wire read_valid,
    input wire [255:0] read_data
);

    wire request, acknowledge;
    wire [511:0] packet, response;
    wire bulk_request, bulk_ack, bulk_overrun;
    wire [255:0] bulk_data;
    wire debug_request, debug_ack, load_request, load_ack;
    wire [511:0] debug_response, load_response;
    wire loader_selected, core_selected;
    wire debug_valid, load_valid;
    wire [2:0] debug_command, load_command;
    wire [28:0] debug_address, load_address;
    wire [255:0] debug_data, load_data;
    wire [31:0] debug_mask, load_mask;

    jtag_mailbox transport (
        .clk(board_clk),
        .tck_pad_i(tck),
        .tms_pad_i(tms),
        .tdi_pad_i(tdi),
        .tdo_pad_o(tdo),
        .calibrated(calibrated),
        .busy(busy),
        .request(request),
        .packet(packet),
        .acknowledge(acknowledge),
        .response(response),
        .bulk_request(bulk_request),
        .bulk_acknowledge(bulk_ack),
        .bulk_data(bulk_data),
        .bulk_overrun(bulk_overrun)
    );

    command_router router (
        .clk(clk),
        .rst(rst),
        .request(request),
        .packet(packet),
        .acknowledge(acknowledge),
        .response(response),
        .busy(busy),
        .command(core_packet),
        .debug_request(debug_request),
        .debug_ack(debug_ack),
        .debug_response(debug_response),
        .load_request(load_request),
        .load_ack(load_ack),
        .load_response(load_response),
        .core_request(core_request),
        .core_ack(core_ack),
        .core_response(core_response),
        .loader_selected(loader_selected),
        .core_selected(core_selected)
    );

    memory_debug debug_access (
        .clk(clk),
        .rst(rst),
        .calibrated(calibrated),
        .request(debug_request),
        .packet(core_packet),
        .acknowledge(debug_ack),
        .response(debug_response),
        .busy(),
        .cmd_ready(memory_ready && !loader_selected),
        .wr_ready(memory_ready),
        .cmd_en(debug_valid),
        .cmd(debug_command),
        .addr(debug_address),
        .wr_data(debug_data),
        .wr_en(),
        .wr_mask(debug_mask),
        .rd_valid(read_valid && !loader_selected),
        .rd_data(read_data)
    );

    memory_loader loader (
        .clk(clk),
        .rst(rst),
        .calibrated(calibrated),
        .request(load_request),
        .packet(core_packet),
        .acknowledge(load_ack),
        .response(load_response),
        .busy(),
        .bulk_request(bulk_request),
        .bulk_acknowledge(bulk_ack),
        .bulk_data(bulk_data),
        .bulk_overrun(bulk_overrun),
        .cmd_ready(memory_ready && loader_selected && !core_selected),
        .wr_ready(memory_ready),
        .cmd_en(load_valid),
        .cmd(load_command),
        .addr(load_address),
        .wr_data(load_data),
        .wr_en(),
        .wr_mask(load_mask),
        .rd_valid(read_valid && loader_selected && !core_selected),
        .rd_data(read_data)
    );

    // One mailbox command uses DDR at a time and keeps ownership until completion.
    assign core_ready = memory_ready && core_selected;
    assign core_read_valid = read_valid && core_selected;
    assign memory_valid = core_selected ? core_valid : loader_selected ? load_valid : debug_valid;
    assign memory_command = core_selected ? core_command :
                            loader_selected ? load_command : debug_command;
    assign memory_address = core_selected ? core_address :
                            loader_selected ? load_address : debug_address;
    assign memory_data = core_selected ? core_data : loader_selected ? load_data : debug_data;
    assign memory_mask = core_selected ? core_mask : loader_selected ? load_mask : debug_mask;

endmodule
