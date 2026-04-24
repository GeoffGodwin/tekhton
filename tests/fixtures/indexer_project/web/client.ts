interface User {
  id: string;
  name: string;
}

export function fetchUser(id: string): Promise<User> {
  return fetch(`/api/users/${id}`).then((r) => r.json() as Promise<User>);
}

export function formatUserName(user: User): string {
  return user.name.trim();
}
