module fifo (
  input logic	clk,
  input logic	rst_n,

  input logic	push,
  input logic	pop,

  input logic	[7:0] data_in,
  output logic	[7:0] data_out,

  output logic	full,
  output logic	empty
 );

	logic	[7:0] mem [0:3];
	
	logic 	[1:0] write_ptr;
	logic	[1:0] read_ptr;

	logic	[2:0] count;

	assign	empty = (count == 3'd0);
	assign	full   = (count == 3'd3);

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
				write_ptr <= write_ptr + 1'b1;
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
