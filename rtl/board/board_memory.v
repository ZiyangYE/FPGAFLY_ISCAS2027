module board_memory (
    input wire board_clk,
    input wire reset_n,
    output wire clk,
    output wire rst,
    output reg calibrated = 0,
    output wire heartbeat,
    output wire pll_locked,
    output wire pll_stopped,
    input wire valid,
    output wire ready,
    input wire [2:0] command,
    input wire [28:0] address,
    input wire [255:0] write_data,
    input wire [31:0] write_mask,
    output wire read_valid,
    output wire [255:0] read_data,
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
    inout wire [3:0] ddr_dqs_n
);

    reg [19:0] startup = 0;
    reg [25:0] heartbeat_counter = 0;
    wire memory_reset_n = reset_n && (&startup);
    wire reference_clk, reference_locked, memory_clk, calibrated_raw;
    (* syn_preserve = 1 *) reg [2:0] reset_sync = 7;

    always @(posedge board_clk) begin
        if (!(&startup)) startup <= startup + 20'd1;
        heartbeat_counter <= heartbeat_counter + 26'd1;
    end

    always @(posedge clk) begin
        reset_sync <= {reset_sync[1:0], !memory_reset_n};
        calibrated <= calibrated_raw;
    end
    assign rst = reset_sync[2];
    assign heartbeat = heartbeat_counter[25];

    reference_pll reference_pll (
        .lock(reference_locked),
        .clkout0(reference_clk),
        .clkout1(),
        .clkout2(),
        .init_clk(board_clk),
        .clkin(board_clk),
        .reset(!reset_n),
        .enclk0(1'b1),
        .enclk1(1'b0),
        .enclk2(1'b0)
    );

    memory_pll Gowin_PLL_inst (
        .lock(pll_locked),
        .clkout0(),
        .clkout1(),
        .clkout2(memory_clk),
        .init_clk(board_clk),
        .clkin(reference_clk),
        .reset(!reference_locked),
        .enclk0(1'b1),
        .enclk1(1'b1),
        .enclk2(pll_stopped)
    );

    wire phy_ready, phy_write_ready, phy_enable, phy_write;
    wire [  2:0] phy_command;
    wire [ 28:0] phy_address;
    wire [255:0] phy_data;
    wire [ 31:0] phy_mask;

    command_buffer commands (
        .clk(clk),
        .rst(rst || !calibrated),
        .in_valid(valid),
        .in_ready(ready),
        .in_cmd(command),
        .in_addr(address),
        .in_data(write_data),
        .in_mask(write_mask),
        .cmd_ready(phy_ready),
        .wr_ready(phy_write_ready),
        .cmd_en(phy_enable),
        .wr_en(phy_write),
        .cmd(phy_command),
        .addr(phy_address),
        .data(phy_data),
        .mask(phy_mask)
    );

    D3_320 u_ddr3 (
        .clk(board_clk),
        .memory_clk(memory_clk),
        .pll_lock(pll_locked),
        .pll_stop(pll_stopped),
        .rst_n(memory_reset_n),
        .clk_out(clk),
        .ddr_rst(),
        .init_calib_complete(calibrated_raw),
        .cmd_ready(phy_ready),
        .cmd(phy_command),
        .cmd_en(phy_enable),
        .addr(phy_address),
        .wr_data_rdy(phy_write_ready),
        .wr_data(phy_data),
        .wr_data_en(phy_write),
        .wr_data_end(phy_write),
        .wr_data_mask(phy_mask),
        .rd_data(read_data),
        .rd_data_valid(read_valid),
        .rd_data_end(),
        .sr_req(1'b0),
        .ref_req(1'b0),
        .sr_ack(),
        .ref_ack(),
        .burst(1'b0),
        .O_ddr_addr(ddr_addr),
        .O_ddr_ba(ddr_bank),
        .O_ddr_cs_n(ddr_cs),
        .O_ddr_ras_n(ddr_ras),
        .O_ddr_cas_n(ddr_cas),
        .O_ddr_we_n(ddr_we),
        .O_ddr_clk(ddr_ck),
        .O_ddr_clk_n(ddr_ck_n),
        .O_ddr_cke(ddr_cke),
        .O_ddr_odt(ddr_odt),
        .O_ddr_reset_n(ddr_reset_n),
        .O_ddr_dqm(ddr_dm),
        .IO_ddr_dq(ddr_dq),
        .IO_ddr_dqs(ddr_dqs),
        .IO_ddr_dqs_n(ddr_dqs_n)
    );

endmodule
