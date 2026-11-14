#include <string>
#include <iostream>
#include <fstream>
#include <vector>
#include <sstream>

class Instruction {
public:
    operandMnemonic mnemonic;
    std::vector<Operand> operands;
    int address;

    //turns string into operand
    void mnemonicfromStr(std::string str){
        if(str == "wait")
        if(str == "shift")
            mnemonic = shift;
        if(str == "setBit")SW
            inst.mnemonic = setBit;
        if(operandMnemonic == "wait")
            inst.mnemonic = blank;

std::string trimWhiteSpace(std::string in);

        
    
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


}
Instruction parseInstruction(const std::string& line){ 
	Instruction inst;
    std::istringstream iss(line);
    std::string operandMnemonic;
    iss >> operandMnemonic;

    std::cout << operandMnemonic << "/n";

    
	


	while(std::getline(operandStream, operandMnemonic, ',')){
        operandMnemonic = trimWhiteSpace(operandMnemonic);


		inst.operands.push_back(operandMnemonic);
	}
	return inst;
}
Operand parseOperand(std::string operandString){
    Operand op;
}

std::string trimWhiteSpace(std::string in) {
		size_t start = in.find_first_not_of(" \t");

		if(start == std::string::npos){
		    return in;	
		}

		in.erase(0, start);

		size_t end = in.find_last_not_of(" /t");
		in.erase(end + 1);
        return in;
}

