// GET que devolve JSON (ou null quando o corpo vem vazio). Falha de rede ou status de erro rejeita a promise.
export async function getJSON(url, params = {}) {
  const query = new URLSearchParams()
  Object.entries(params).forEach(([key, value]) => {
    if (value !== undefined && value !== null) query.append(key, value)
  })
  const response = await fetch(`${url}?${query}`, {
    headers: { Accept: "application/json", "X-Requested-With": "XMLHttpRequest" },
    credentials: "same-origin"
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const text = await response.text()
  return text ? JSON.parse(text) : null
}
