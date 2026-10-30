// Track who issued each DDR read; register the next owner before its data arrives.
module read_tags #(
    parameter DEPTH = 96
) (
    input  wire clk,
    input  wire rst,
    input  wire issue,
    input  wire issue_stream,
    input  wire response_valid,
    output wire direct_response,
    output wire stream_response
);

    localparam AW = $clog2(DEPTH);
    reg [DEPTH-1:0] tags = 0;
    reg [AW-1:0] head = 0, tail = 0;
    reg current = 0;
    wire [AW-1:0] next_head = head == DEPTH - 1 ? {AW{1'b0}} : head + 1'b1;
    assign direct_response = response_valid && !current;
    assign stream_response = response_valid && current;

    always @(posedge clk) begin
        if (rst) begin
            head <= 0;
            tail <= 0;
            current <= 0;
        end else begin
            if (issue) begin
                tags[tail] <= issue_stream;
                tail <= tail == DEPTH - 1 ? {AW{1'b0}} : tail + 1'b1;
            end
            if (response_valid) begin
                head <= next_head;
                // If push supplies the next head on this clock, take it directly from the input.
                current <= (issue && tail == next_head) ? issue_stream : tags[next_head];
            end else if (issue && tail == head) current <= issue_stream;
        end
    end

endmodule
