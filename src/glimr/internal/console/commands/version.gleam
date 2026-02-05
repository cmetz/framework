import glimr/console/command.{type Args, type Command}

/// The console command description.
const description = "Display your application's Glimr version"

/// Define the console command and its properties.
///
pub fn command() -> Command {
  command.new()
  |> command.description(description)
  |> command.handler(run)
}

/// Execute the console command.
///
fn run(_args: Args) -> Nil {
  command.print_glimr_version()
}

/// Console command's entry point
///
pub fn main() {
  command.run(command())
}
