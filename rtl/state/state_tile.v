// Request data is sampled each clock and used only when read_pending is set.
// Reset clears valid flags; data registers do not need a reset.
// Wait for all pending reads and writes before changing phase.
// Each row is integrated once per step and written when fire_valid && fire_ready.
module state_tile #(
    parameter LANES = 6,
    ROWS = 3970
) (
    input wire clk,
    input wire rst,
    input wire [1:0] phase,
    input wire raw_read,
    input wire raw_write,
    input wire [12:0] raw_address,
    input wire [LANES*24-1:0] raw_data,
    output wire [LANES*24-1:0] read_data,
    input wire dense_valid,
    output wire dense_ready,
    input wire [12:0] dense_row,
    input wire [LANES*18-1:0] dense_drive,
    output wire fire_valid,
    input wire fire_ready,
    output wire [12:0] fire_row,
    output wire [LANES-1:0] fire,
    output wire dense_failed,
    input wire event_valid,
    output wire event_ready,
    input wire [12:0] event_row,
    input wire [6:0] event_lane,
    input wire signed [17:0] event_weight,
    output wire event_done,
    output wire event_failed
);

    localparam RAW = 0;
    localparam DENSE = 1;
    localparam EVENT = 2;
    reg pending = 0, read_pending = 0;
    reg [12:0] requested_row;
    wire [LANES*18-1:0] requested_drive;
    reg [12:0] pending_row;
    reg [LANES*18-1:0] pending_drive;
    reg [LANES*24-1:0] codes0, codes1;
    reg [LANES*18-1:0] drive0, drive1;
    reg [12:0] row0, row1;
    reg head = 0, tail = 0;
    reg [1:0] count = 0;
    wire integrate_ready;
    wire pop = count != 0 && integrate_ready && phase == DENSE;
    // Count each outstanding read against the buffer capacity; RAM takes two clocks.
    // A pop frees a slot for a new read on the same clock.
    // Capacity is two buffered rows plus one row held at the RAM output.
    // The second row lets a full buffer pop while the RAM output is held.
    wire push = pending && count < 2;
    assign dense_ready = phase == DENSE && !rst && !dense_failed &&
        ({1'b0,count}+pending+read_pending < 3 || pop);
    wire issue = dense_valid && dense_ready;

    always @(posedge clk) begin
        if (rst) begin
            pending <= 0;
            read_pending <= 0;
            head <= 0;
            tail <= 0;
            count <= 0;
        end else begin
            read_pending <= issue;
            if (read_pending) pending <= 1;
            else if (push) pending <= 0;
            requested_row <= dense_row;
            if (read_pending) pending_row <= requested_row;
            if (push) begin
                if (tail) row1 <= pending_row;
                else row0 <= pending_row;
                tail <= !tail;
            end
            if (pop) head <= !head;
            case ({
                push, pop
            })
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
            endcase
        end
    end
    genvar control_lane, request_bit;

    generate
        for (
            control_lane = 0; control_lane < LANES; control_lane = control_lane + 1
        ) begin : local_control
            wire first_enable  /* synthesis syn_keep=1 */;
            wire second_enable  /* synthesis syn_keep=1 */;
            wire response_enable  /* synthesis syn_keep=1 */;
            LUT2 #(
                .INIT(4'h8)
            ) response_gate (
                .I0(read_pending),
                .I1(1'b1),
                .F (response_enable)
            );

            LUT2 #(
                .INIT(4'h8)
            ) first_gate (
                .I0(push),
                .I1(tail == 0),
                .F (first_enable)
            );

            LUT2 #(
                .INIT(4'h8)
            ) second_gate (
                .I0(push),
                .I1(tail == 1),
                .F (second_enable)
            );

            for (
                request_bit = 0; request_bit < 18; request_bit = request_bit + 1
            ) begin : request_data
                if (request_bit < 13) begin : explicit_data
                    DFFE capture (
                        .Q  (requested_drive[control_lane*18+request_bit]),
                        .D  (dense_drive[control_lane*18+request_bit]),
                        .CLK(clk),
                        .CE (1'b1)
                    );

                end else begin : upper_data
                    // The interface is 18 bits wide; unused input bits are constant.
                    reg captured;

                    always @(posedge clk) captured <= dense_drive[control_lane*18+request_bit];
                    assign requested_drive[control_lane*18+request_bit] = captured;
                end
            end

            always @(posedge clk) begin
                if (first_enable) begin
                    codes0[control_lane*24+:24] <= read_data[control_lane*24+:24];
                    drive0[control_lane*18+:18] <= pending_drive[control_lane*18+:18];
                end
                if (second_enable) begin
                    codes1[control_lane*24+:24] <= read_data[control_lane*24+:24];
                    drive1[control_lane*18+:18] <= pending_drive[control_lane*18+:18];
                end
                if (response_enable)
                    pending_drive[control_lane*18+:18] <= requested_drive[control_lane*18+:18];
            end
        end
    endgenerate

    wire [LANES*24-1:0] dense_codes, event_codes;
    wire erv, ewv;
    wire [12:0] era, ewa;
    wire [6:0] event_write_lane;
    wire [LANES*24/9-1:0] write_bank_mask;
    genvar bank;

    generate
        for (bank = 0; bank < LANES * 24 / 9; bank = bank + 1) begin : write_banks
            assign write_bank_mask[bank] = phase != EVENT ||
            event_write_lane == (bank*9)/24 || event_write_lane == (bank*9+8)/24;
        end
    endgenerate

    wire integrated_valid;
    assign fire_valid = integrated_valid && phase == DENSE;
    row_integrator #(
        .LANES(LANES)
    ) integrate (
        .clk(clk),
        .rst(rst),
        .valid(count != 0 && phase == DENSE),
        .ready(integrate_ready),
        .row(head ? row1 : row0),
        .codes(head ? codes1 : codes0),
        .drive(head ? drive1 : drive0),
        .out_valid(integrated_valid),
        .out_ready(fire_ready && phase == DENSE),
        .out_row(fire_row),
        .out_codes(dense_codes),
        .fire(fire),
        .failed(dense_failed)
    );

    event_update #(
        .LANES(LANES)
    ) update_event (
        .clk(clk),
        .rst(rst),
        .valid(event_valid && phase == EVENT),
        .ready(event_ready),
        .row(event_row),
        .lane(event_lane),
        .weight(event_weight),
        .done(event_done),
        .failed(event_failed),
        .row_read(erv),
        .row_read_address(era),
        .row_data(read_data),
        .row_write(ewv),
        .row_write_address(ewa),
        .row_write_data(event_codes),
        .row_write_lane(event_write_lane)
    );

    localparam ADDRESS_BANKS = LANES * 24 / 9;
    localparam ADDRESS_GROUPS = (ADDRESS_BANKS + 15) / 16;
    wire [ADDRESS_BANKS*13-1:0] bank_read_addresses, bank_write_addresses;
    genvar address_group, address_bit, address_bank;

    generate
        for (
            address_group = 0; address_group < ADDRESS_GROUPS; address_group = address_group + 1
        ) begin : address_groups
            wire [12:0] read_first  /* synthesis syn_keep=1 */;
            wire [12:0] write_first  /* synthesis syn_keep=1 */;
            wire [12:0] read_selected  /* synthesis syn_keep=1 */;
            wire [12:0] write_selected  /* synthesis syn_keep=1 */;
            // Keep a separate mux for each RAM group to limit long routes.
            for (address_bit = 0; address_bit < 13; address_bit = address_bit + 1) begin : bits
                LUT3 #(
                    .INIT(8'hca)
                ) read0 (
                    .I0(raw_address[address_bit]),
                    .I1(dense_row[address_bit]),
                    .I2(phase[0]),
                    .F (read_first[address_bit])
                );

                LUT3 #(
                    .INIT(8'hca)
                ) read1 (
                    .I0(read_first[address_bit]),
                    .I1(era[address_bit]),
                    .I2(phase[1]),
                    .F (read_selected[address_bit])
                );

                LUT3 #(
                    .INIT(8'hca)
                ) write0 (
                    .I0(raw_address[address_bit]),
                    .I1(fire_row[address_bit]),
                    .I2(phase[0]),
                    .F (write_first[address_bit])
                );

                LUT3 #(
                    .INIT(8'hca)
                ) write1 (
                    .I0(write_first[address_bit]),
                    .I1(ewa[address_bit]),
                    .I2(phase[1]),
                    .F (write_selected[address_bit])
                );

            end
            for (
                address_bank = 0; address_bank < 16; address_bank = address_bank + 1
            ) begin : outputs
                if (address_group * 16 + address_bank < ADDRESS_BANKS) begin : used
                    assign bank_read_addresses[(address_group*16+address_bank)*13+:13] = read_selected;
                    assign bank_write_addresses[(address_group*16+address_bank)*13+:13] = write_selected;
                end
            end
        end
    endgenerate

    state_ram #(
        .LANES(LANES),
        .ROWS (ROWS)
    ) storage (
        clk,
        !rst && (phase == RAW ? raw_read : phase == DENSE ? issue : erv),
        bank_read_addresses,
        read_data,
        !rst && (phase == RAW ? raw_write : phase == DENSE ? fire_valid && fire_ready : ewv),
        bank_write_addresses,
        phase == RAW ? raw_data : phase == DENSE ? dense_codes : event_codes,
        write_bank_mask
    );

endmodule
