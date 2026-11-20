
# Instruction memory: 128 words x 5 bits
# Target technology: IHP SG13G2

word_size = 5
num_words = 128
num_banks = 1

# Single read/write port
num_rw_ports = 1
num_r_ports = 0
num_w_ports = 0

# IHP SG13G2 technology
tech_name = "ihp"

process_corners = ["TT"]
supply_voltages = [1.2]
temperatures = [25]

# Physical generation
check_lvsdrc = False

output_path = "instruction_memory_128x5"
output_name = "instruction_memory_128x5"

