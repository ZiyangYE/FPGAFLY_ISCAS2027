module jtag_mailbox (
    input wire clk,
    input wire tck_pad_i,
    input wire tms_pad_i,
    input wire tdi_pad_i,
    output wire tdo_pad_o,
    input wire calibrated,
    input wire busy,
    output reg request = 0,
    output reg [511:0] packet = 0,
    input wire acknowledge,
    input wire [511:0] response,
    input wire bulk_acknowledge,
    output wire bulk_request,
    output wire [255:0] bulk_data,
    output wire bulk_overrun
);

    wire jtck, jtdi, shift_capture, update, sel, sel_bulk;
    reg [511:0] shift_reg = 0;
    GW_JTAG jtag (
        .tck_pad_i(tck_pad_i),
        .tms_pad_i(tms_pad_i),
        .tdi_pad_i(tdi_pad_i),
        .tdo_pad_o(tdo_pad_o),
        .tck_o(jtck),
        .tdi_o(jtdi),
        .test_logic_reset_o(),
        .run_test_idle_er1_o(),
        .run_test_idle_er2_o(),
        .shift_dr_capture_dr_o(shift_capture),
        .pause_dr_o(),
        .update_dr_o(update),
        .enable_er1_o(sel),
        .enable_er2_o(sel_bulk),
        .tdo_er1_i(shift_reg[0]),
        .tdo_er2_i(1'b0)
    );

    bulk_receiver bulk (
        .clk(clk),
        .jtck(jtck),
        .jtdi(jtdi),
        .shift_capture(shift_capture),
        .select_bulk(sel_bulk),
        .acknowledge(bulk_acknowledge),
        .request(bulk_request),
        .data(bulk_data),
        .overrun(bulk_overrun)
    );

    // Sample the registered TAP outputs at 50 MHz; USER1 commands use 1 MHz TCK.
    (* syn_preserve=1 *) reg [3:0] tck_sync = 0;
    (* syn_preserve=1 *) reg [1:0]
        tdi_sync = 0,
        sc_sync = 0,
        up_sync = 0,
        sel_sync = 0,
        ack_sync = 0,
        cal_sync = 0,
        busy_sync = 0;
    reg sc_previous = 0, up_previous = 0;
    reg [31:0] update_count = 0, last_bits = 0, last_magic = 0, last_command = 0;
    reg [9:0] bits = 0;
    reg [31:0] last_seq = 32'hffffffff;
    reg [511:0] cached_response = 0;
    reg ack_previous = 0;
    wire pending = request != ack_sync[1];

    always @(posedge clk) begin
        tck_sync <= {tck_sync[2:0], jtck};
        tdi_sync <= {tdi_sync[0], jtdi};
        sc_sync <= {sc_sync[0], shift_capture};
        up_sync <= {up_sync[0], update};
        sel_sync <= {sel_sync[0], sel};
        ack_sync <= {ack_sync[0], acknowledge};
        cal_sync <= {cal_sync[0], calibrated};
        busy_sync <= {busy_sync[0], busy};
        ack_previous <= ack_sync[1];
        up_previous <= up_sync[1];
        if (sel_sync[1] && up_sync[1] && !up_previous) begin
            update_count <= update_count + 1;
            last_bits <= bits;
            last_magic <= shift_reg[31:0];
            last_command <= shift_reg[63:32];
            // The low word must contain the ASCII marker DDR3 before a command is accepted.
            if (bits == 512 && !pending && shift_reg[31:0] == 32'h44445233 && shift_reg[39:32] != 0 && shift_reg[63:32] != last_seq) begin
                request <= ~request;
                last_seq <= shift_reg[63:32];
            end
        end
        if (tck_sync[2] && !tck_sync[3]) begin
            sc_previous <= sc_sync[1];
            if (sel_sync[1] && sc_sync[1]) begin
                if (!sc_previous) begin
                    bits <= 0;
                end else bits <= bits + 10'd1;
            end
        end
    end
    wire take_packet = sel_sync[1] && up_sync[1] && !up_previous && bits == 512 &&
        !pending && shift_reg[31:0] == 32'h44445233 && shift_reg[39:32] != 0 && shift_reg[63:32] != last_seq;
    wire shift_enable = tck_sync[2] && !tck_sync[3] && sel_sync[1] && sc_sync[1];
    reg [511:0] capture_value;

    always @* begin
        capture_value = cached_response;
        capture_value[31:0] = 32'h44445233;
        capture_value[64] = pending || busy_sync[1];
        capture_value[66] = cal_sync[1];
        if (cached_response[31:0] == 0) begin
            capture_value[415:384] = update_count;
            capture_value[447:416] = last_bits;
            capture_value[479:448] = last_magic;
            capture_value[511:480] = last_command;
        end
    end
    wire [511:0] next_shift = sc_previous ? {tdi_sync[1], shift_reg[511:1]} : capture_value;
    genvar word;

    generate
        for (word = 0; word < 16; word = word + 1) begin : local_control
            wire packet_enable  /* synthesis syn_keep=1 */;
            wire cache_enable  /* synthesis syn_keep=1 */;
            wire local_shift_enable  /* synthesis syn_keep=1 */;
            LUT2 #(
                .INIT(4'h8)
            ) packet_gate (
                .I0(take_packet),
                .I1(!pending),
                .F (packet_enable)
            );

            LUT2 #(
                .INIT(4'h6)
            ) cache_gate (
                .I0(ack_previous),
                .I1(ack_sync[1]),
                .F (cache_enable)
            );

            LUT2 #(
                .INIT(4'h8)
            ) shift_gate (
                .I0(tck_sync[2] && !tck_sync[3]),
                .I1(sel_sync[1] && sc_sync[1]),
                .F (local_shift_enable)
            );

            always @(posedge clk) begin
                if (packet_enable) packet[word*32+:32] <= shift_reg[word*32+:32];
                if (cache_enable) cached_response[word*32+:32] <= response[word*32+:32];
                if (local_shift_enable) shift_reg[word*32+:32] <= next_shift[word*32+:32];
            end
        end
    endgenerate

endmodule
