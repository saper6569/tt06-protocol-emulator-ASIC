#include <cctype>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr int WAIT_TIMER = 0;
constexpr int WAIT_FOR_BASE = 1;
constexpr int SHIFT_BASE = 5;
constexpr int TOGGLE_IO_MODE_BASE = 9;
constexpr int TOGGLE_WAIT_FOR_VALUE = 13;
constexpr int TOGGLE_SHIFT_DIR = 14;
constexpr int TOGGLE_COUNTER_BASE = 15;
constexpr int INSTRUCTION_WIDTH = 5;
constexpr int MAX_COUNTER_BITS = (1 << INSTRUCTION_WIDTH) - 21;
std::string lowercase(std::string value) {
    for (char& character : value) {
        character = static_cast<char>(
            std::tolower(static_cast<unsigned char>(character)));
    }
    return value;
}

int parse_index(const std::string& token, const std::string& prefix,
                int maximum) {
    if (token.rfind(prefix, 0) != 0 || token.size() == prefix.size()) {
        throw std::runtime_error("expected " + prefix + "0.." +
                                 std::to_string(maximum));
    }

    const std::string digits = token.substr(prefix.size());
    std::size_t parsed = 0;
    int value = 0;
    try {
        value = std::stoi(digits, &parsed);
    } catch (const std::exception&) {
        throw std::runtime_error("invalid index '" + token + "'");
    }
    if (parsed != digits.size() || value < 0 || value > maximum) {
        throw std::runtime_error("index out of range in '" + token + "'");
    }
    return value;
}

int encode(const std::vector<std::string>& tokens, int counter_bits) {
    const int shift_one = 15 + counter_bits;
    const int shift_zero = shift_one + 1;
    const int jump_base = shift_zero + 1;

    if (tokens.size() == 2 && tokens[0] == "wait" &&
        tokens[1] == "timer") {
        return WAIT_TIMER;
    }
    if (tokens.size() == 2 && tokens[0] == "wait" &&
        tokens[1].rfind("io", 0) == 0) {
        return WAIT_FOR_BASE + parse_index(tokens[1], "io", 3);
    }
    if (tokens.size() == 2 && tokens[0] == "shift" &&
        tokens[1].rfind("io", 0) == 0) {
        return SHIFT_BASE + parse_index(tokens[1], "io", 3);
    }
    if (tokens.size() == 2 && tokens[0] == "shift" && tokens[1] == "1") {
        return shift_one;
    }
    if (tokens.size() == 2 && tokens[0] == "shift" && tokens[1] == "0") {
        return shift_zero;
    }
    if (tokens.size() == 3 && tokens[0] == "toggle" &&
        tokens[1] == "io_mode") {
        return TOGGLE_IO_MODE_BASE + parse_index(tokens[2], "io", 3);
    }
    if (tokens.size() == 2 && tokens[0] == "toggle" &&
        tokens[1] == "wait_for_value") {
        return TOGGLE_WAIT_FOR_VALUE;
    }
    if (tokens.size() == 2 && tokens[0] == "toggle" &&
        tokens[1] == "shift_dir") {
        return TOGGLE_SHIFT_DIR;
    }
    if (tokens.size() == 3 && tokens[0] == "toggle" &&
        tokens[1] == "counter") {
        return TOGGLE_COUNTER_BASE +
               parse_index(tokens[2], "bit", counter_bits - 1);
    }
    if (tokens.size() == 2 && tokens[0] == "jump") {
        std::size_t parsed = 0;
        int section = 0;
        try {
            section = std::stoi(tokens[1], &parsed);
        } catch (const std::exception&) {
            throw std::runtime_error("jump expects section 0..3");
        }
        if (parsed != tokens[1].size() || section < 0 || section > 3) {
            throw std::runtime_error("jump expects section 0..3");
        }
        return jump_base + section;
    }
    throw std::runtime_error("unknown instruction or invalid operands");
}
}  // namespace

int main(int argc, char* argv[]) {
    int counter_bits = MAX_COUNTER_BITS;
    std::string input_path;
    std::string output_path;
    for (int i = 1; i < argc; ++i) {
        const std::string argument = argv[i];
        if (argument == "--counter-bits" || argument == "-c") {
            if (++i >= argc) {
                std::cerr << "Missing counter width\n";
                return 1;
            }
            try {
                std::size_t parsed = 0;
                counter_bits = std::stoi(argv[i], &parsed);
                if (parsed != std::string(argv[i]).size() ||
                    counter_bits < 1 || counter_bits > MAX_COUNTER_BITS) {
                    throw std::runtime_error("out of range");
                }
            } catch (const std::exception&) {
                std::cerr << "Counter bits must be between 1 and "
                          << MAX_COUNTER_BITS << '\n';
                return 1;
            }
        } else if (argument == "-o") {
            if (++i >= argc) {
                std::cerr << "Missing output file after -o\n";
                return 1;
            }
            output_path = argv[i];
        } else if (!argument.empty() && argument[0] == '-') {
            std::cerr << "Unknown option: " << argument << '\n';
            return 1;
        } else if (input_path.empty()) {
            input_path = argument;
        } else {
            std::cerr << "Unexpected argument: " << argument << '\n';
            return 1;
        }
    }
    if (input_path.empty()) {
        std::cerr << "Usage: assembler [--counter-bits <bits>] <input-file> "
                     "[-o <output-file>]\n";
        return 1;
    }

    std::ifstream input(input_path);
    if (!input) {
        std::cerr << "Could not open input file: " << input_path << '\n';
        return 1;
    }

    std::ofstream output_file;
    std::ostream* output = &std::cout;
    if (!output_path.empty()) {
        output_file.open(output_path);
        if (!output_file) {
            std::cerr << "Could not open output file: " << output_path << '\n';
            return 1;
        }
        output = &output_file;
    }

    std::string line;
    int line_number = 0;
    while (std::getline(input, line)) {
        ++line_number;
        const auto comment = line.find_first_of("#;");
        if (comment != std::string::npos) {
            line.erase(comment);
        }

        std::istringstream line_stream(line);
        std::vector<std::string> tokens;
        std::string token;
        while (line_stream >> token) {
            tokens.push_back(lowercase(token));
        }
        if (tokens.empty()) {
            continue;
        }

        try {
            *output << encode(tokens, counter_bits) << '\n';
        } catch (const std::exception& error) {
            std::cerr << "Line " << line_number << ": " << error.what()
                      << '\n';
            return 1;
        }
    }
}
