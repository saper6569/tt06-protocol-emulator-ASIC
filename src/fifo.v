/*
 * Synchronous FIFO, SIZE entries of WIDTH bits.
 *
 * data_out shows the oldest entry (not valid while empty). On a rising edge,
 * pop removes it and push stores data_in. A push while full is accepted only
 * if there is a pop in the same cycle; a pop while empty is ignored.
 *
 * SIZE does not need to be a power of 2.
 */

module fifo #(
    parameter WIDTH = 8,
    parameter SIZE  = 4
) (
    input  wire             clk,
    input  wire             rst_n,

    input  wire             push,
    input  wire             pop,

    input  wire [WIDTH-1:0] data_in,
    output wire [WIDTH-1:0] data_out,

    output wire             full,
    output wire             empty
);
    // At least 1 bit, so that SIZE = 1 still works.
    localparam PTR_WIDTH = (SIZE > 1) ? $clog2(SIZE) : 1;

    reg [WIDTH-1:0]          mem [0:SIZE-1];
    reg [PTR_WIDTH-1:0]      write_ptr;
    reg [PTR_WIDTH-1:0]      read_ptr;
    reg [$clog2(SIZE+1)-1:0] count;

    assign empty    = (count == 0);
    assign full     = (count == SIZE);
    assign data_out = mem[read_ptr];

    wire do_pop  = pop && !empty;
    wire do_push = push && (!full || do_pop);  // the pop frees the slot

    always @(posedge clk) begin
        if (!rst_n) begin
            write_ptr <= 0;
            read_ptr  <= 0;
            count     <= 0;
        end else begin
            if (do_push) begin
                mem[write_ptr] <= data_in;
                write_ptr      <= (write_ptr == SIZE - 1) ? 0 : write_ptr + 1'b1;
            end

            if (do_pop)
                read_ptr <= (read_ptr == SIZE - 1) ? 0 : read_ptr + 1'b1;

            case ({do_push, do_pop})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;  // none, or one in and one out
            endcase
        end
    end
endmodule
