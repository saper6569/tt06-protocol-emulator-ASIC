#include "Instruction.hpp"
#include <cstddef>
#include <sstream>
#include <string>
#include <vector>
#include <fstream>
#include <iostream>
#include <string_view>
#include <regex>

class Parser{
private:
    std::string_view trimWhitspace(std::string_view str){
        const std::string_view whitspace = " \t\f\r\v\n";
        auto strBegin = str.find_first_not_of(whitspace);

        if(strBegin == std::string::npos){
            return "";
        }

        auto strEnd = str.find_last_not_of(whitspace);
        return str.substr(strBegin, strEnd + 1 - strBegin);
    }

    tt06::Instr parseInstr(const std::string_view line){
        tt06::Instr instruction;
        std::istringstream iss(line);

        std::string mnemonic;
        iss >> mnemonic;
        instruction.mnemonic = parseMnemonic(mnemonic);
        std::string operand;
        std::vector<std::string> rawOperands;

        while(std::getline(iss, operand, ',')){
            rawOperands.emplace_back(trimWhitspace(operand));
        }


        auto format = getOperandsFormat(instruction.mnemonic);
        if (rawOperands.size() != format.size())
            ;//TODO: mismatching operand and format
        for(size_t i = 0; i < format.size(); i++){
            instruction.operands.emplace_back(
                    parseOperand(rawOperands[i], format[i])
                );
        }

    }
    tt06::Operand parseOperand (std::string raw_operand, tt06::OperandType expectedType){
        if(std::regex_match(raw_operand, getOperandRegex(expectedType))){
            switch (expectedType){
                case tt06::GPIO_loc:
                case tt06::bit:
                case tt06::bit_loc:
                case tt06::addr:
                default:
                    break;
            }
        }
        else
            ;        //TODO: throw 
    }
    std::regex getOperandRegex (tt06::OperandType type){
        switch (type){
            case tt06::GPIO_loc:
                return std::regex(R"(gpio_[0-9]|in_[0-9]|out_[0-9])");
            case tt06::bit:
                return std::regex(R"([01])");
            case tt06::bit_loc:
                return std::regex(R"([a-zA-Z0-9_])");
            case tt06::addr:
                return std::regex(R"([a-zA-Z0-9_])");
        }
    }
    std::vector<tt06::OperandType> getOperandsFormat(tt06::OperandMnemonic mnemonic){
        switch (mnemonic) {
            case tt06::wait:
                return {tt06::GPIO_loc, tt06::bit};
            case tt06::shift:
                return {tt06::GPIO_loc, tt06::bit};
            case tt06::setBit:
                return {tt06::bit_loc};
            case tt06::jmp:
                return {tt06::addr};
            default:

                break;
        }
    } 
    tt06::OperandMnemonic parseMnemonic(std::string_view mnemonic){
        tt06::OperandMnemonic out;
        if(mnemonic == "wait")
            out = tt06::wait;
        else if(mnemonic == "shift")
            out = tt06::shift;
        else if(mnemonic == "setBit")
            out = tt06::setBit;
        else if(mnemonic == "wait")
            out = tt06::blank;
        else 
            out = NULL;
            //TODO: exceptions
        return out;
    }
public:
    std::vector<tt06::Instr> parseFile(const std::string& path){
        std::ifstream file(path);
            
         if(!file.is_open()) {
            std::cerr << "Could not open file:" << path << "\n";
            return std::nullopt_t;
        }

        std::string line;
        std::vector<tt06::Instr> Instructions;
        while (std::getline(file, line)) {
            tt06::Instr currInstr;
            currInstr = parseInstr(line);
            
            
            std::cout << line;
        }
    }
};
