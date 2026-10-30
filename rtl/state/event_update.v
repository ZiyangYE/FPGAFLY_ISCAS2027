// Event updates share the row port with integration, one phase at a time.
// Register the RAM request; updates that need no extra read finish in SUM.
module event_update #(
    parameter LANES = 42
) (
    input wire clk,
    input wire rst,
    input wire valid,
    output wire ready,
    input wire [12:0] row,
    input wire [6:0] lane,
    input wire signed [17:0] weight,
    output reg done = 0,
    output reg failed = 0,
    output wire row_read,
    output wire [12:0] row_read_address,
    input wire [LANES*24-1:0] row_data,
    output wire row_write,
    output wire [12:0] row_write_address,
    output reg [LANES*24-1:0] row_write_data,
    output wire [6:0] row_write_lane
);

    localparam IDLE = 0;
    localparam READ = 1;
    localparam DECODE = 2;
    localparam SUM = 3;
    localparam READ_WAIT = 9;
    reg [ 3:0] state = IDLE;
    reg [12:0] saved_row;
    reg [ 6:0] saved_lane;
    reg signed [17:0] saved_weight, saved_u;
    reg signed [18:0] sum;
    localparam SELECT_GROUPS = (LANES + 7) / 8;
    reg [SELECT_GROUPS*24-1:0] selected_groups;
    wire [SELECT_GROUPS*192-1:0] padded_row = {
        {(SELECT_GROUPS * 192 - LANES * 24) {1'b0}}, row_data
    };
    wire [23:0] old_code = selected_groups[saved_lane[6:3]*24+:24];
    genvar select_group;

    generate
        for (
            select_group = 0; select_group < SELECT_GROUPS; select_group = select_group + 1
        ) begin : local_select
            wire [191:0] group_data = padded_row[select_group*192+:192];
            wire read_enable  /* synthesis syn_keep=1 */;
            LUT2 #(
                .INIT(4'h8)
            ) read_gate (
                .I0(!rst),
                .I1(state == READ),
                .F (read_enable)
            );

            always @(posedge clk)
                if (read_enable)
                    selected_groups[select_group*24+:24] <= group_data[saved_lane[2:0]*24+:24];
        end
    endgenerate

    assign row_write_lane = saved_lane;
    wire signed [17:0] old_u, old_g;
    wire [4:0] old_ref;
    state_decode decode (
        .code(old_code),
        .u(old_u),
        .g(old_g),
        .refractory(old_ref)
    );

    wire signed [17:0] capped = sum < -19'sd131072 ? -18'sd131072 :
        sum > 19'sd131071 ? 18'sd131071 : sum[17:0];
    wire [23:0] encoded;
    state_encode encode (
        .u(saved_u),
        .g(capped),
        .refractory(5'b0),
        .code(encoded)
    );

    assign ready = state == IDLE;
    assign row_read = valid && ready && !rst;
    assign row_read_address = row;
    wire [23:0] write_code = encoded;
    assign row_write = state == SUM && !rst;
    assign row_write_address = saved_row;
    // Only the 9-bit banks containing saved_lane are written.
    // Banks shared with another lane need readback to preserve its bits.
    genvar bank;

    generate
        for (bank = 0; bank < LANES * 24 / 9; bank = bank + 1) begin : write_banks
            localparam OFFSET = (bank * 9) % 24;
            if (OFFSET <= 15) begin

                always @* row_write_data[bank*9+:9] = write_code[OFFSET+:9];
            end else begin
                localparam LEFT = 24 - OFFSET;

                always @* begin
                    row_write_data[bank*9+:LEFT] = saved_lane == (bank*9)/24 ?
                    write_code[OFFSET+:LEFT] : row_data[bank*9+:LEFT];
                    row_write_data[bank*9+LEFT+:9-LEFT] = saved_lane == (bank*9+8)/24 ?
                    write_code[0+:9-LEFT] : row_data[bank*9+LEFT+:9-LEFT];
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        done <= 0;
        if (rst) begin
            state <= IDLE;
            failed <= 0;
        end else
            case (state)
                IDLE:
                if (valid) begin
                    saved_row <= row;
                    saved_lane <= lane;
                    saved_weight <= weight;
                    failed <= 0;
                    state <= READ_WAIT;
                end
                READ_WAIT: state <= READ;
                READ: state <= DECODE;
                DECODE: begin
                    if (old_ref != 0) begin
                        done <= 1;
                        state <= IDLE;
                    end else begin
                        saved_u <= old_u;
                        sum <= $signed(
                            {old_g[17], old_g}
                        ) + $signed(
                            {saved_weight[17], saved_weight}
                        );

                        state <= SUM;
                    end
                end
                SUM: begin
                    done <= 1;
                    state <= IDLE;
                end
            endcase
    end

endmodule
