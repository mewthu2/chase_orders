// Lê a coluna SKU de uma planilha .csv (vírgula ou ponto e vírgula). Sem coluna SKU, usa a primeira.
export function parseSkus(text) {
  const lines = text.split(/\r\n|\n|\r/).filter((line) => line.trim() !== "")
  if (lines.length === 0) return []

  const separator = lines[0].includes(";") && !lines[0].includes(",") ? ";" : ","
  const clean = (value) => (value || "").trim().replace(/"/g, "")
  const header = lines[0].split(separator).map((h) => clean(h).toLowerCase())
  let skuIndex = header.indexOf("sku")
  if (skuIndex === -1) skuIndex = 0

  return lines.slice(1)
    .map((line) => clean(line.split(separator)[skuIndex]))
    .filter((sku) => sku !== "")
}

// Baixa linhas como .csv. Com Excel em mente: ";" separa as colunas e o BOM garante os acentos.
// A lista "SKU,Quantidade" da consulta unitária mantém o formato antigo (vírgula, sem BOM), pois pode ser reimportada.
export function downloadCsv(filename, rows, { separator = ";", bom = true } = {}) {
  const cell = (value) => {
    const text = value === undefined || value === null ? "" : String(value)
    return new RegExp(`["${separator}\\n]`).test(text) ? `"${text.replace(/"/g, '""')}"` : text
  }
  const body = rows.map((row) => row.map(cell).join(separator)).join("\r\n")
  const blob = new Blob([(bom ? "﻿" : "") + body], { type: "text/csv;charset=utf-8;" })
  const url = URL.createObjectURL(blob)
  const link = document.createElement("a")
  link.href = url
  link.download = filename
  document.body.appendChild(link)
  link.click()
  link.remove()
  URL.revokeObjectURL(url)
}

export const today = () => new Date().toISOString().slice(0, 10)
