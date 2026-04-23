#include <string>

class Engine {
public:
    Engine(const std::string& name) : name_(name) {}

    std::string run(const std::string& input) {
        return name_ + ":" + input;
    }

private:
    std::string name_;
};
