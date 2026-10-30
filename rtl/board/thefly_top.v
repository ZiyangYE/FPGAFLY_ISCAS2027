module thefly_top (
    input wire clk,
    input wire rst_n,
    input wire tck_pad_i,
    input wire tms_pad_i,
    input wire tdi_pad_i,
    output wire tdo_pad_o,
    output wire [14:0] ddr_addr,
    output wire [2:0] ddr_bank,
    output wire ddr_cs,
    output wire ddr_ras,
    output wire ddr_cas,
    output wire ddr_we,
    output wire ddr_ck,
    output wire ddr_ck_n,
    output wire ddr_cke,
    output wire ddr_odt,
    output wire ddr_reset_n,
    output wire [3:0] ddr_dm,
    inout wire [31:0] ddr_dq,
    inout wire [3:0] ddr_dqs,
    inout wire [3:0] ddr_dqs_n,
    output wire [5:0] state_led
);

    wire app_clk, app_reset, calibrated, heartbeat, pll_locked, pll_stopped, busy;
    wire request, acknowledge;
    wire [511:0] packet, response;
    wire core_valid, core_ready, core_read_valid;
    wire [  2:0] core_command;
    wire [ 28:0] core_address;
    wire [255:0] core_write_data;
    wire [ 31:0] core_write_mask;
    wire memory_valid, memory_ready, read_valid;
    wire [ 2:0] memory_command;
    wire [28:0] memory_address;
    wire [255:0] memory_write_data, read_data;
    wire [31:0] memory_write_mask;

    host_bridge host (
        .board_clk(clk),
        .clk(app_clk),
        .rst(app_reset),
        .calibrated(calibrated),
        .tck(tck_pad_i),
        .tms(tms_pad_i),
        .tdi(tdi_pad_i),
        .tdo(tdo_pad_o),
        .busy(busy),
        .core_request(request),
        .core_packet(packet),
        .core_ack(acknowledge),
        .core_response(response),
        .core_valid(core_valid),
        .core_ready(core_ready),
        .core_command(core_command),
        .core_address(core_address),
        .core_data(core_write_data),
        .core_mask(core_write_mask),
        .core_read_valid(core_read_valid),
        .memory_valid(memory_valid),
        .memory_ready(memory_ready),
        .memory_command(memory_command),
        .memory_address(memory_address),
        .memory_data(memory_write_data),
        .memory_mask(memory_write_mask),
        .read_valid(read_valid),
        .read_data(read_data)
    );

    frame_engine #(
        .STEPS(1000),
        .LANES(42),
        .PREFETCH(64)
    ) core (
        .clk(app_clk),
        .rst(app_reset),
        .calibrated(calibrated),
        .request(request),
        .packet(packet),
        .acknowledge(acknowledge),
        .response(response),
        .busy(),
        .cmd_ready(core_ready),
        .wr_ready(memory_ready),
        .cmd_en(),
        .cmd_valid(core_valid),
        .cmd(core_command),
        .addr(core_address),
        .wr_data(core_write_data),
        .wr_en(),
        .wr_mask(core_write_mask),
        .rd_valid(core_read_valid),
        .rd_data(read_data),
        .trace_fire_valid(),
        .trace_fire_row(),
        .trace_fire_mask(),
        .trace_section()
    );

    board_memory memory (
        .board_clk(clk),
        .reset_n(rst_n),
        .clk(app_clk),
        .rst(app_reset),
        .calibrated(calibrated),
        .heartbeat(heartbeat),
        .pll_locked(pll_locked),
        .pll_stopped(pll_stopped),
        .valid(memory_valid),
        .ready(memory_ready),
        .command(memory_command),
        .address(memory_address),
        .write_data(memory_write_data),
        .write_mask(memory_write_mask),
        .read_valid(read_valid),
        .read_data(read_data),
        .ddr_addr(ddr_addr),
        .ddr_bank(ddr_bank),
        .ddr_cs(ddr_cs),
        .ddr_ras(ddr_ras),
        .ddr_cas(ddr_cas),
        .ddr_we(ddr_we),
        .ddr_ck(ddr_ck),
        .ddr_ck_n(ddr_ck_n),
        .ddr_cke(ddr_cke),
        .ddr_odt(ddr_odt),
        .ddr_reset_n(ddr_reset_n),
        .ddr_dm(ddr_dm),
        .ddr_dq(ddr_dq),
        .ddr_dqs(ddr_dqs),
        .ddr_dqs_n(ddr_dqs_n)
    );

    assign state_led = ~{heartbeat, busy, memory_ready, pll_stopped, pll_locked, calibrated};

endmodule
