CXX = g++
CXXFLAGS = -std=c++20 -Wall -Wextra -Wpedantic 
SRC = src/main.cpp
OUT = bin/assembler

all:
	@mkdir -p bin
	$(CXX) $(CXXFLAGS) $(SRC) -o $(OUT) 
clean:
	rm -rf bin/
