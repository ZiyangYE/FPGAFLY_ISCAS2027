// Keep each input pixel's pulse phase across 100 ms windows.
module input_phases (
    input clk, rst, start, resume,
    input [17:0] read_data,
    output read_enable, write_enable, done,
    output reg [9:0] address = 0,
    output [17:0] write_data
);
    localparam IDLE=0, GRAY_READ=1, GRAY_LOAD=2, PHASE_READ=3;
    localparam PHASE_LOAD=4, REDUCE=5, WRITE=6, DONE=7;
    reg [2:0] state = IDLE;
    reg [7:0] pixel = 0, previous_gray;
    reg [17:0] phase_sum;
    assign read_enable = state == GRAY_READ || state == PHASE_READ;
    assign write_enable = state == WRITE;
    assign write_data = {6'b0, phase_sum[11:0]};
    assign done = state == DONE;

    always @(posedge clk) begin
        if (rst) state <= IDLE;
        else if (start) begin
            pixel <= 0;
            address <= 0;
            state <= GRAY_READ;
        end else case (state)
            GRAY_READ: state <= GRAY_LOAD;
            GRAY_LOAD: begin
                previous_gray <= read_data[7:0];
                address <= {2'b01, pixel};
                if (resume) state <= PHASE_READ;
                else begin
                    phase_sum <= (pixel * 18'd365 + 18'd95) >> 1;
                    state <= REDUCE;
                end
            end
            PHASE_READ: state <= PHASE_LOAD;
            PHASE_LOAD: begin
                phase_sum <= previous_gray * 18'd1000 + read_data[11:0];
                state <= REDUCE;
            end
            REDUCE:
                if (phase_sum >= 2550) phase_sum <= phase_sum - 18'd2550;
                else state <= WRITE;
            WRITE:
                if (pixel == 255) state <= DONE;
                else begin
                    pixel <= pixel + 1'b1;
                    address <= {2'b0, pixel} + 10'd1;
                    state <= GRAY_READ;
                end
            DONE: state <= IDLE;
        endcase
    end
endmodule
