pub struct Handler {
    pub name: String,
}

impl Handler {
    pub fn new(name: &str) -> Self {
        Handler { name: name.to_string() }
    }

    pub fn handle(&self) -> String {
        format!("handled by {}", self.name)
    }
}
