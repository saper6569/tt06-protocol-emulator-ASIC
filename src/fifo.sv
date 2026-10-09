module fifo #(
    parameter WIDTH = 8,
    parameter SIZE = 4
    )(
  input wire clk,
  input wire rst_n,

  input wire push,
  input wire pop,

  input  wire 	[WIDTH-1:0] data_in,
  output wire [WIDTH-1:0] data_out,

  output wire full,
  output wire empty
 );

	reg     [WIDTH-1:0] mem [0:SIZE-1];
	
	reg     [$clog2(SIZE) - 1:0] write_ptr;
	reg     [$clog2(SIZE) - 1:0] read_ptr;

	reg     [$clog2(SIZE+1)-1:0] count;

	assign	empty = (count == 0);
	assign	full   = (count == SIZE);

	assign data_out = mem[read_ptr];

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			write_ptr <= 0;
			read_ptr  <= 0;
			count	  <= 0;
		end else begin
			//push
			if(push && !full) begin
				mem[write_ptr] <= data_in;
				write_ptr <= write_ptr +1'b1;
			end
			//pop
			if(pop && !empty) begin
				read_ptr <= read_ptr + 1'b1;
			end

			//update number of stored entries
			case({
				push && !full,
				pop  && !empty
			})

				2'b10: count <= count + 1'b1;
				2'b01: count <= count - 1'b1;

				default: count <= count;
			endcase
		end
	end
endmodule
