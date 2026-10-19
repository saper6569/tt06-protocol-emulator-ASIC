#include <string>
#include <iostream>
#include <fstream>
#include <vector>

enum operandType{
    address,
    immediate,
    complileImmediate,
    controlBit
};

struct Operand{
    operandType type;
    int value;
};
struct Instruction{
    std::string mnemonic;
    std::vector<Operand> operands;
    int address;
};

        
    
int main(int argc, char * argv[]) {
    bool namedOutput = false;

    //handle when output file is named with -o flag 
    if (argc == 4) {
        if (std::string(argv[2]) == "-o")
                namedOutput = true;
        else {
            std::cerr << "Error: unidentified operand:" << argv[2] << " is an unidentified flag\n";
            return 1;
        }
    }
    else if (argc == 2);
    else {
        std::cerr << "Error: unidentified  number of operands:" << argc << "\n";
        return 1;
    }

    std::ifstream file(argv[1]);
        
    if(!file.is_open()) {
        std::cerr << "Could not open file:" << argv[1] << "\n";
        return 1;
    }

}
