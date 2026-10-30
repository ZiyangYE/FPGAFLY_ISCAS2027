// Accumulate signed linear scores and select the largest score after the frame.
module linear_readout (
    clk, rst, bias_valid, bias_page,
    bias_data, add_valid, add_word, classify,
    page, add_done, class_done, winner,
    page_data
);
    input clk;
    input rst;
    input bias_valid;
    input [1:0] bias_page;
    input [255:0] bias_data;
    input add_valid;
    input [31:0] add_word;
    input classify;
    input [31:0] page;
    output add_done;
    output class_done;
    output [3:0] winner;
    output [255:0] page_data;

    localparam IDLE=0, READ=1, SELECT=2, WRITE=3, CLASS_READ=4, CLASS_COMPARE=5, DONE=6;
    reg [2:0] state = IDLE;
    reg [31:0] coefficient_word;
    (* syn_ramstyle="registers" *) reg signed [47:0] scores[0:9];
    reg signed [47:0] bank0, bank1, bank2, value, contribution;
    wire signed [47:0] coefficient = {{40{coefficient_word[11]}}, coefficient_word[11:4]};
    reg signed [47:0] best, candidate;
    reg [3:0] index, winner;
    reg [255:0] page_data;
    assign add_done = state == WRITE;
    assign class_done = state == DONE;
    integer k;

    always @* begin
        page_data = 0;
        case (page)
            0: for (k=0; k<4; k=k+1)
                page_data[k*64+:64] = {{16{scores[k][47]}}, scores[k]};
            1: for (k=0; k<4; k=k+1)
                page_data[k*64+:64] = {{16{scores[k+4][47]}}, scores[k+4]};
            2: begin
                page_data[63:0] = {{16{scores[8][47]}}, scores[8]};
                page_data[127:64] = {{16{scores[9][47]}}, scores[9]};
            end
        endcase
    end

    integer b;
    always @(posedge clk) begin
        if (bias_valid) begin
            case (bias_page)
                0: for (b=0; b<4; b=b+1) scores[b] <= bias_data[b*64+:48];
                1: for (b=0; b<4; b=b+1) scores[b+4] <= bias_data[b*64+:48];
                2: begin
                    scores[8] <= bias_data[47:0];
                    scores[9] <= bias_data[111:64];
                end
            endcase
        end
        if (rst) state <= IDLE;
        else case (state)
            IDLE: begin
                if (add_valid) begin
                    coefficient_word <= add_word;
                    state <= READ;
                end else if (classify) begin
                    best <= scores[0];
                    winner <= 0;
                    index <= 1;
                    state <= CLASS_READ;
                end
            end
            READ: begin
                bank0 <= scores[{2'b0, coefficient_word[1:0]}];
                bank1 <= scores[{2'b01, coefficient_word[1:0]}];
                bank2 <= coefficient_word[0] ? scores[9] : scores[8];
                contribution <= coefficient <<< coefficient_word[17:12];
                state <= SELECT;
            end
            SELECT: begin
                value <= coefficient_word[3:2] == 0 ? bank0 :
                    coefficient_word[3:2] == 1 ? bank1 : bank2;
                state <= WRITE;
            end
            WRITE: begin
                scores[coefficient_word[3:0]] <= value + contribution;
                state <= IDLE;
            end
            CLASS_READ: begin
                candidate <= scores[index];
                state <= CLASS_COMPARE;
            end
            CLASS_COMPARE: begin
                if (candidate > best) begin
                    best <= candidate;
                    winner <= index;
                end
                if (index == 9) state <= DONE;
                else begin
                    index <= index + 1'b1;
                    state <= CLASS_READ;
                end
            end
            DONE: state <= IDLE;
        endcase
    end
endmodule
