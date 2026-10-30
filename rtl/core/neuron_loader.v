// Decode DDR state records and write complete rows to the neuron array.
module neuron_loader #(
    parameter N=166700, LANES=42
) (
    input clk, rst, start,
    input stream_valid,
    input [255:0] stream_data,
    output done,
    output reg stream_start = 0,
    output [31:0] stream_base,
    output [23:0] stream_lines,
    output stream_take,
    output raw_write,
    output [12:0] raw_address,
    output [LANES*24-1:0] raw_data
);
    localparam IDLE=0, WARM_READ=1, WARM_ACCEPT=2, WARM_COMMIT=3;
    reg [1:0] state = IDLE;
    assign stream_base = 32'h18000000;
    assign stream_lines = (N + 3) / 4;

    reg [12:0] raw_row = 0;
    reg [6:0] raw_lane = 0;
    reg [17:0] init_id = 0;
    reg warm_last = 0, warm_done = 0, warm_row_last = 0;
    reg [LANES*24-1:0] raw_codes = 0;
    reg initial_valid = 0;
    reg [17:0] fetch_id = 0;
    reg fetch_done = 0;
    reg [23:0] initial_code;
    reg [40:0] fetched_cell;
    reg fetched_valid = 0;
    wire [23:0] fetched_code;
    state_encode initial_encoder (
        .u(fetched_cell[17:0]),
        .g(fetched_cell[35:18]),
        .refractory(fetched_cell[40:36]),
        .code(fetched_code)
    );

    wire warm_accept = state == WARM_ACCEPT && initial_valid;
    reg warm_write_valid = 0, warm_clear = 0, warm_commit = 0;
    reg [ 6:0] warm_write_lane;
    reg [23:0] warm_write_code;
    reg [12:0] warm_write_row;
    // Delay row data and its write enable by the same number of clocks.
    always @(posedge clk) begin
        warm_write_valid <= !rst && warm_accept;
        warm_clear <= !rst && (start || state == WARM_COMMIT);
        warm_commit <= !rst && state == WARM_COMMIT;
        warm_write_lane <= raw_lane;
        warm_write_code <= initial_code;
        warm_write_row <= raw_row;
    end
    genvar warm_lane;

    generate
        for (warm_lane = 0; warm_lane < LANES; warm_lane = warm_lane + 1) begin : warm_capture

            always @(posedge clk) begin
                if (warm_clear) raw_codes[warm_lane*24+:24] <= 0;
                else if (warm_write_valid && warm_write_lane == warm_lane)
                    raw_codes[warm_lane*24+:24] <= warm_write_code;
            end
        end
    endgenerate

    wire decode_ready = !initial_valid || warm_accept;
    wire fetch_ready = !fetched_valid || decode_ready;
    wire warm_ready = state != IDLE && !fetch_done && fetch_ready;
    wire warm_fetch = warm_ready && stream_valid;
    // Buffer raw and encoded rows so DDR reception can stall independently of encoding.
    always @(posedge clk) begin
        if (rst || start) begin
            fetch_id <= 0;
            fetch_done <= 0;
            initial_valid <= 0;
            fetched_valid <= 0;
        end else begin
            if (fetch_ready) begin
                fetched_valid <= warm_fetch;
                if (warm_fetch) begin
                    fetched_cell <= stream_data[fetch_id[1:0]*64+:41];
                    fetch_id <= fetch_id + 1'b1;
                    fetch_done <= fetch_id == N - 1;
                end
            end
            if (decode_ready) begin
                initial_valid <= fetched_valid;
                if (fetched_valid) begin
                    initial_code <= fetched_code;
                end
            end
        end
    end


    assign done = state == WARM_COMMIT && warm_done;
    assign stream_take = warm_ready && (fetch_id[1:0] == 3 || fetch_id == N - 1);
    assign raw_write = warm_commit;
    assign raw_address = warm_write_row;
    assign raw_data = raw_codes;
    always @(posedge clk) begin
        stream_start <= 0;
        if (rst) state <= IDLE;
        else if (start) begin
            raw_row <= 0;
            raw_lane <= 0;
            init_id <= 0;
            warm_last <= N == 1;
            warm_done <= 0;
            warm_row_last <= LANES == 1;
            state <= WARM_READ;
        end else case (state)
            WARM_READ: begin
                stream_start <= 1;
                state <= WARM_ACCEPT;
            end

            WARM_ACCEPT:
                if (initial_valid) begin
                    init_id <= init_id + 1'b1;
                    warm_last <= init_id == N - 2;
                    warm_done <= warm_last;
                    if (warm_row_last || warm_last) state <= WARM_COMMIT;
                    else begin
                        raw_lane <= raw_lane + 1'b1;
                        warm_row_last <= raw_lane == LANES - 2;
                        state <= WARM_ACCEPT;
                    end
                end

            WARM_COMMIT: begin
                raw_lane <= 0;
                raw_row <= raw_row + 1'b1;
                warm_row_last <= LANES == 1;
                if (warm_done) begin
                    state <= IDLE;
                end else state <= WARM_ACCEPT;
            end

        endcase
    end
endmodule
