interface GreetingProps {
  name: string;
}

export function Greeting(props: GreetingProps) {
  return <span className="greeting">Hello, {props.name}!</span>;
}
