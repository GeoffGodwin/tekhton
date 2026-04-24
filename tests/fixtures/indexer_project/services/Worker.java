package services;

public class Worker {
    private final String name;

    public Worker(String name) {
        this.name = name;
    }

    public String process(String input) {
        return name + ":" + input;
    }
}
