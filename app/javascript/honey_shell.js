// Casca do Honey.Chase: menu por área, busca rápida (Ctrl + K), ajuda da tela (?), mapa do
// sistema, tour guiado, dicas flutuantes, tamanho da letra e menu do usuário.
// Os dados (telas liberadas, glossário, passos do tour) vêm do JSON #honeyData do layout.

// Tudo num bloco: um `const $` global taparia o jQuery dos scripts das telas ($(...).click não ligaria nada).
(() => {
const $ = (sel, root = document) => root.querySelector(sel)
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel))
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])
const norm = (s) => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
const motionOn = () => !window.matchMedia('(prefers-reduced-motion: reduce)').matches
const store = {
  get (key, fallback) { try { const v = localStorage.getItem(`honey:${key}`); return v == null ? fallback : JSON.parse(v) } catch { return fallback } },
  set (key, value) { try { localStorage.setItem(`honey:${key}`, JSON.stringify(value)) } catch { /* modo privado */ } }
}
const setCookie = (name, value) => { document.cookie = `${name}=${value}; path=/; max-age=31536000; SameSite=Lax` }

const body = document.body
const data = (() => { try { return JSON.parse($('#honeyData')?.textContent || '{}') } catch { return {} } })()
const layers = () => $('#layers')
const isDesktop = () => window.matchMedia('(min-width: 1081px)').matches
const collapsed = () => body.dataset.sidebar === 'collapsed' && isDesktop()

/* ---------------------------------------------------------------------------
   Dicas flutuantes (data-tip)
   --------------------------------------------------------------------------- */
let tipEl = null
function showTip (target) {
  const text = target.dataset.tip
  if (!text) return
  // Na barra completa os itens já mostram o nome: a dica só aparece com ela recolhida.
  if (target.matches('.sb-link[data-tip]:not(.sb-expand)') && !collapsed()) return
  hideTip()
  tipEl = document.createElement('div')
  tipEl.className = 'hc-tip'
  tipEl.textContent = text
  document.body.appendChild(tipEl)
  const r = target.getBoundingClientRect(); const t = tipEl.getBoundingClientRect()
  const sidebar = target.closest('.sidebar')
  let left = sidebar ? r.right + 10 : r.left + r.width / 2 - t.width / 2
  let top = sidebar ? r.top + r.height / 2 - t.height / 2 : r.bottom + 8
  if (!sidebar && top + t.height > window.innerHeight - 8) top = r.top - t.height - 8
  left = Math.max(8, Math.min(left, window.innerWidth - t.width - 8))
  tipEl.style.left = `${left}px`; tipEl.style.top = `${Math.max(8, top)}px`
}
function hideTip () { tipEl?.remove(); tipEl = null }
document.addEventListener('mouseover', (e) => { const t = e.target.closest('[data-tip]'); if (t) showTip(t) })
document.addEventListener('mouseout', (e) => { if (e.target.closest('[data-tip]')) hideTip() })
document.addEventListener('focusin', (e) => { const t = e.target.closest('[data-tip]'); if (t && t.matches(':focus-visible')) showTip(t) })
document.addEventListener('focusout', hideTip)
window.addEventListener('scroll', hideTip, true)

/* ---------------------------------------------------------------------------
   Barra lateral
   --------------------------------------------------------------------------- */
function initSidebar () {
  const nav = $('#sbNav')
  if (!nav) return

  // Ao entrar no Honey todas as áreas vêm recolhidas (a da tela atual abre).
  // As que a pessoa abrir ficam abertas só durante esta sessão do navegador.
  const session = {
    get () { try { return JSON.parse(sessionStorage.getItem('honey:openAreas') || '[]') } catch { return [] } },
    set (v) { try { sessionStorage.setItem('honey:openAreas', JSON.stringify(v)) } catch { /* modo privado */ } }
  }
  const openAreas = new Set(session.get())
  $$('.sb-section', nav).forEach((section) => {
    if (openAreas.has(section.dataset.area)) {
      section.classList.remove('is-closed')
      $('.sb-section-title', section).setAttribute('aria-expanded', 'true')
    }
  })
  nav.addEventListener('click', (e) => {
    const title = e.target.closest('.sb-section-title')
    if (title) {
      if (collapsed()) return
      const section = title.closest('.sb-section')
      const closed = section.classList.toggle('is-closed')
      title.setAttribute('aria-expanded', String(!closed))
      closed ? openAreas.delete(section.dataset.area) : openAreas.add(section.dataset.area)
      session.set(Array.from(openAreas))
      return
    }
    const groupBtn = e.target.closest('.sb-group-btn')
    if (groupBtn) {
      if (collapsed()) { showFlyout(groupBtn.closest('.sb-group')); return }
      const group = groupBtn.closest('.sb-group')
      const open = !group.classList.contains('is-open')
      group.classList.toggle('is-open', open)
      groupBtn.setAttribute('aria-expanded', String(open))
      if (open && motionOn()) { group.classList.add('is-opening'); setTimeout(() => group.classList.remove('is-opening'), 600) }
    }
  })

  // Leva o menu até o item da tela atual (o título da área fica fixo no topo: folga de 56px).
  const active = $('.sb-link.is-active', nav)
  if (active) {
    const nr = nav.getBoundingClientRect(); const ar = active.getBoundingClientRect()
    if (ar.bottom > nr.bottom - 14 || ar.top < nr.top + 56) nav.scrollTop += ar.top - nr.top - nr.height / 2
  }

  const setCollapsed = (value) => {
    body.dataset.sidebar = value ? 'collapsed' : 'expanded'
    setCookie('honey_sidebar', body.dataset.sidebar)
    hideFlyout(); hideTip()
  }
  $('#sbCollapse')?.addEventListener('click', () => setCollapsed(true))
  $('#sbExpand')?.addEventListener('click', () => setCollapsed(false))

  // Barra recolhida: passar o mouse num grupo abre o painel com as telas dele.
  let flyTimer
  nav.addEventListener('mouseover', (e) => {
    if (!collapsed()) return
    const group = e.target.closest('.sb-group')
    if (group) { clearTimeout(flyTimer); showFlyout(group) }
  })
  nav.addEventListener('mouseleave', () => { flyTimer = setTimeout(hideFlyout, 260) })
  document.addEventListener('mouseover', (e) => { if (e.target.closest('.flyout')) clearTimeout(flyTimer) })

  // Celular: o menu abre por cima da tela.
  const closeMobile = () => body.classList.remove('sidebar-open')
  $('#mobileToggle')?.addEventListener('click', () => body.classList.add('sidebar-open'))
  $('#sidebarOverlay')?.addEventListener('click', closeMobile)

  const guided = $('#guidedToggle')
  const toggleGuided = () => {
    const on = body.dataset.guided !== 'on'
    body.dataset.guided = on ? 'on' : 'off'
    guided.setAttribute('aria-checked', String(on))
    setCookie('honey_guided', body.dataset.guided)
  }
  guided?.addEventListener('click', toggleGuided)
  guided?.addEventListener('keydown', (e) => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); toggleGuided() } })
}

let flyoutEl = null
function showFlyout (group) {
  hideFlyout()
  const btn = $('.sb-group-btn', group); const section = group.closest('.sb-section')
  flyoutEl = document.createElement('div')
  flyoutEl.className = 'flyout'
  flyoutEl.style.cssText = section.getAttribute('style') || ''
  const label = $('.sb-label', btn)?.firstChild?.textContent?.trim() || ''
  flyoutEl.innerHTML = `<h4>${esc(label)}</h4>${$('.sb-children-list', group).innerHTML}`
  document.body.appendChild(flyoutEl)
  const r = btn.getBoundingClientRect()
  const top = Math.min(r.top, window.innerHeight - flyoutEl.offsetHeight - 12)
  flyoutEl.style.left = `${r.right + 8}px`; flyoutEl.style.top = `${Math.max(12, top)}px`
  flyoutEl.addEventListener('mouseleave', hideFlyout)
}
function hideFlyout () { flyoutEl?.remove(); flyoutEl = null }

/* ---------------------------------------------------------------------------
   Topo: sombra ao rolar, tamanho da letra e menu do usuário
   --------------------------------------------------------------------------- */
function initTopbar () {
  const topbar = $('#topbar')
  const onScroll = () => topbar?.classList.toggle('is-scrolled', window.scrollY > 4)
  window.addEventListener('scroll', onScroll, { passive: true }); onScroll()

  // Zoom do sistema por usuário: aplica na hora e salva no servidor (com debounce).
  const fontScale = $('#fontScale')
  if (fontScale) {
    const min = Number(fontScale.dataset.min); const max = Number(fontScale.dataset.max)
    const step = Number(fontScale.dataset.step) || 10
    const valueEl = $('.font-scale-value', fontScale)
    let scale = Number(fontScale.dataset.scale) || 100
    let saveTimer
    const refreshButtons = () => {
      $("[data-delta='-10']", fontScale).disabled = scale <= min
      $("[data-delta='10']", fontScale).disabled = scale >= max
    }
    const apply = (next) => {
      scale = Math.min(max, Math.max(min, next))
      document.documentElement.style.zoom = scale === 100 ? '' : `${scale}%`
      valueEl.textContent = `${scale}%`
      valueEl.classList.remove('font-scale-value--pop'); void valueEl.offsetWidth; valueEl.classList.add('font-scale-value--pop')
      refreshButtons()
      clearTimeout(saveTimer)
      saveTimer = setTimeout(() => {
        fetch(fontScale.dataset.url, {
          method: 'PATCH',
          headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'X-CSRF-Token': $("meta[name='csrf-token']")?.content },
          body: JSON.stringify({ font_scale: scale })
        })
      }, 400)
    }
    fontScale.addEventListener('click', (e) => {
      const btn = e.target.closest('button'); if (!btn) return
      if (btn.hasAttribute('data-reset')) apply(100)
      else apply(scale + Math.sign(Number(btn.dataset.delta)) * step)
    })
    refreshButtons()
  }

  const userBtn = $('#userBtn'); const userMenu = $('#userMenu')
  if (userBtn && userMenu) {
    const close = () => { userMenu.hidden = true; userBtn.setAttribute('aria-expanded', 'false') }
    userBtn.addEventListener('click', (e) => {
      e.stopPropagation()
      const open = userMenu.hidden
      userMenu.hidden = !open; userBtn.setAttribute('aria-expanded', String(open))
    })
    document.addEventListener('click', (e) => { if (!userMenu.contains(e.target)) close() })
    userMenu.addEventListener('click', (e) => { if (e.target.closest('[data-act]')) close() })
  }

  // Fecha o "logar como" ao clicar fora.
  const imp = $('.impersonation-switcher')
  if (imp) document.addEventListener('click', (e) => { if (!imp.contains(e.target)) imp.open = false })
}

/* ---------------------------------------------------------------------------
   Camadas (busca, ajuda, mapa)
   --------------------------------------------------------------------------- */
// Painéis que vivem na página (com scripts e campos já ligados) vão para a camada ao abrir e
// voltam para o lugar de origem ao fechar, em vez de serem apagados.
function rescueKept () {
  layers().querySelectorAll('[data-keep-layer]').forEach((node) => {
    node.classList.remove('is-closing')
    node.style.removeProperty('opacity')
    document.getElementById(node.dataset.keepLayer)?.appendChild(node)
  })
}
function openKept (holderId) {
  const holder = document.getElementById(holderId); if (!holder) return
  closeTour(); hideFlyout(); hideTip()
  rescueKept(); layers().innerHTML = ''
  Array.from(holder.children).forEach((node) => { node.dataset.keepLayer = holderId; layers().appendChild(node) })
  setTimeout(() => $('select, input, textarea', layers())?.focus(), 60)
}
function closeLayers () {
  const drawer = $('.drawer', layers())
  if (drawer && motionOn()) {
    drawer.classList.add('is-closing')
    $('.backdrop', layers())?.style.setProperty('opacity', '0')
    setTimeout(() => { rescueKept(); layers().innerHTML = '' }, 280)
  } else {
    rescueKept(); layers().innerHTML = ''
  }
  hideTip()
}
function openTemplate (id) {
  closeTour(); hideFlyout(); hideTip()
  rescueKept(); layers().innerHTML = ''
  const tpl = $(`#${id}`); if (!tpl) return null
  layers().appendChild(tpl.content.cloneNode(true))
  return layers()
}
function openHelp (focus) {
  const root = openTemplate('helpTemplate'); if (!root) return
  if (focus === 'glossario') setTimeout(() => $('#glossario', root)?.scrollIntoView({ behavior: motionOn() ? 'smooth' : 'auto' }), 300)
}
function openMap () {
  const root = openTemplate('mapTemplate'); if (!root) return
  const input = $('#mapFilter', root)
  setTimeout(() => input?.focus(), 60)
  input?.addEventListener('input', () => {
    const q = norm(input.value.trim())
    $$('.map-item', root).forEach((item) => item.classList.toggle('is-hidden', q !== '' && !norm(item.dataset.filter).includes(q)))
    $$('.map-group', root).forEach((group) => group.classList.toggle('is-hidden', !$('.map-item:not(.is-hidden)', group)))
    $$('.map-sec', root).forEach((sec) => sec.classList.toggle('is-hidden', !$('.map-group:not(.is-hidden)', sec)))
  })
}

/* ----- Busca rápida (Ctrl + K) ----- */
let palItems = []; let palSel = 0
function paletteIndex () {
  const search = data.search || { screens: [], extras: [], glossary: [] }
  const rows = search.screens.map((s) => ({ ...s, group: 'Telas', hay: norm([s.label, s.path, s.desc, s.keys].join(' ')) }))
  search.extras.forEach((s) => rows.push({ ...s, group: s.path, hay: norm([s.label, s.path, s.desc, s.keys].join(' ')) }))
  search.glossary.forEach((g) => rows.push({ id: `termo-${g.term}`, label: g.term, desc: g.text, icon: 'fas fa-book', path: 'Glossário', group: 'Glossário', glossary: true, hay: norm(`${g.term} ${g.text}`) }))
  return rows
}
function highlight (text, q) {
  if (!q) return esc(text)
  const plain = norm(text); const i = plain.indexOf(q)
  if (i < 0) return esc(text)
  return `${esc(text.slice(0, i))}<mark>${esc(text.slice(i, i + q.length))}</mark>${esc(text.slice(i + q.length))}`
}
function openPalette () {
  closeTour(); hideFlyout(); hideTip()
  const index = paletteIndex()
  rescueKept(); layers().innerHTML = `<div class="backdrop" data-close></div>
    <div class="palette" role="dialog" aria-label="Buscar tela ou ação">
      <div class="palette-input"><i class="fas fa-search"></i><input id="palInput" type="text" placeholder="O que você precisa? Ex.: rastreio, nota fiscal, cupom…" autocomplete="off" spellcheck="false"><kbd>Esc</kbd></div>
      <div class="palette-results" id="palResults"></div>
      <div class="palette-foot"><span><kbd>↑</kbd><kbd>↓</kbd> navegar</span><span><kbd>Enter</kbd> abrir</span><span><kbd>Esc</kbd> fechar</span></div>
    </div>`
  const input = $('#palInput'); const results = $('#palResults')
  const recent = store.get('recent', [])
  const render = () => {
    const q = norm(input.value.trim())
    let list
    if (!q) {
      const byId = Object.fromEntries(index.map((r) => [r.id, r]))
      const rec = recent.map((id) => byId[id]).filter(Boolean).map((r) => ({ ...r, group: 'Abertas recentemente' }))
      list = rec.concat(index.filter((r) => r.group === 'Ações'))
      if (!list.length) list = index.filter((r) => r.group === 'Telas').slice(0, 8)
    } else {
      const words = q.split(/\s+/)
      list = index.map((r) => {
        if (!words.every((w) => r.hay.includes(w))) return null
        const label = norm(r.label)
        const score = (label.startsWith(q) ? 0 : label.includes(q) ? 1 : 2) + (r.glossary ? 3 : 0)
        return { ...r, score }
      }).filter(Boolean).sort((a, b) => a.score - b.score).slice(0, 30)
    }
    palItems = list; palSel = 0
    if (!list.length) {
      results.innerHTML = `<div class="pal-empty"><b>Nada encontrado para "${esc(input.value)}"</b>Tente outra palavra, abra o <a href="#" data-act="map">Mapa do sistema</a> ou a <a href="#" data-act="help">Ajuda</a>.</div>`
      return
    }
    let html = ''; let last = null
    list.forEach((r, i) => {
      if (r.group !== last) { html += `<div class="pal-group">${esc(r.group)}</div>`; last = r.group }
      const tag = r.glossary ? 'button type="button"' : `a href="${esc(r.url)}"`
      const close = r.glossary ? 'button' : 'a'
      html += `<${tag} class="pal-item${i === 0 ? ' is-sel' : ''}" data-i="${i}"><span class="pi"><i class="${esc(r.icon)}"></i></span><span class="pt"><b>${highlight(r.label, q)}</b><small>${esc(r.desc || '')}</small></span><span class="path">${esc(r.path || '')}</span></${close}>`
    })
    results.innerHTML = html
  }
  const choose = (i) => {
    const r = palItems[i]; if (!r) return
    if (r.glossary) { openHelp('glossario'); return }
    store.set('recent', [r.id].concat(recent.filter((id) => id !== r.id)).slice(0, 5))
    window.location.href = r.url
  }
  const move = (d) => {
    if (!palItems.length) return
    palSel = (palSel + d + palItems.length) % palItems.length
    $$('.pal-item', results).forEach((el) => el.classList.toggle('is-sel', Number(el.dataset.i) === palSel))
    $(`.pal-item[data-i="${palSel}"]`, results)?.scrollIntoView({ block: 'nearest' })
  }
  input.addEventListener('input', render)
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); move(1) } else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1) } else if (e.key === 'Enter') { e.preventDefault(); choose(palSel) }
  })
  results.addEventListener('click', (e) => {
    const item = e.target.closest('.pal-item'); if (!item) return
    e.preventDefault(); choose(Number(item.dataset.i))
  })
  results.addEventListener('mousemove', (e) => {
    const item = e.target.closest('.pal-item'); if (!item || Number(item.dataset.i) === palSel) return
    palSel = Number(item.dataset.i)
    $$('.pal-item', results).forEach((el) => el.classList.toggle('is-sel', el === item))
  })
  render(); setTimeout(() => input.focus(), 20)
}

/* ---------------------------------------------------------------------------
   Tour guiado
   --------------------------------------------------------------------------- */
let tourIdx = 0; let tourSteps = []
function closeTour () { document.getElementById('tourLayer')?.remove() }
function startTour () {
  rescueKept(); layers().innerHTML = ''; hideFlyout(); hideTip()
  if (!isDesktop()) body.classList.add('sidebar-open')
  tourSteps = (data.tour || []).filter((s) => s.center || $(s.target))
  tourIdx = 0
  store.set('tourSeen', true)
  renderTour()
}
function renderTour () {
  closeTour()
  const step = tourSteps[tourIdx]
  if (!step) { body.classList.remove('sidebar-open'); return }
  const layer = document.createElement('div')
  layer.id = 'tourLayer'
  layer.className = 'tour-layer'
  const last = tourIdx === tourSteps.length - 1
  const dots = tourSteps.map((_, i) => `<span class="${i === tourIdx ? 'on' : ''}"></span>`).join('')
  const nav = `<div class="tour-foot"><div class="tour-dots">${dots}</div>
    ${tourIdx > 0 ? '<button type="button" class="btn btn-ghost btn-sm" data-tour-act="prev">Voltar</button>' : '<button type="button" class="btn btn-ghost btn-sm" data-tour-act="end">Pular</button>'}
    <button type="button" class="btn btn-primary btn-sm" data-tour-act="${last ? 'end' : 'next'}">${last ? 'Concluir' : 'Próximo'}</button></div>`
  if (step.center) {
    const first = tourIdx === 0
    layer.innerHTML = `<div class="tour-backdrop"></div><div class="tour-center" role="dialog" aria-label="${esc(step.title)}">
      <div class="big-ic"><i class="${esc(step.icon)}"></i></div><h3>${esc(step.title)}</h3><p>${esc(step.text)}</p>
      <div class="tour-row">${first ? '<button type="button" class="btn btn-secondary" data-tour-act="end">Agora não</button><button type="button" class="btn btn-primary" data-tour-act="next"><i class="fas fa-play"></i>Começar o tour</button>' : '<button type="button" class="btn btn-primary" data-tour-act="end">Concluir</button>'}</div></div>`
  } else {
    const target = $(step.target)
    target.scrollIntoView({ block: 'nearest' })
    const r = target.getBoundingClientRect(); const pad = 6
    layer.innerHTML = `<div class="tour-hole" style="top:${r.top - pad}px;left:${r.left - pad}px;width:${r.width + pad * 2}px;height:${r.height + pad * 2}px"></div>
      <div class="tour-card" role="dialog" aria-label="${esc(step.title)}"><div class="tag">Passo ${tourIdx} de ${tourSteps.length - 2}</div><h4>${esc(step.title)}</h4><p>${esc(step.text)}</p>${nav}</div>`
    layers().appendChild(layer)
    const card = $('.tour-card', layer); const c = card.getBoundingClientRect()
    let left; let top
    if (step.side === 'right') { left = r.right + 18; top = r.top + Math.min(r.height / 2 - c.height / 2, 40) } else if (step.side === 'top') { left = r.left; top = r.top - c.height - 18 } else { left = r.left + r.width / 2 - c.width / 2; top = r.bottom + 18 }
    card.style.left = `${Math.max(16, Math.min(left, window.innerWidth - c.width - 16))}px`
    card.style.top = `${Math.max(16, Math.min(top, window.innerHeight - c.height - 16))}px`
  }
  if (!layer.isConnected) layers().appendChild(layer)
  layer.addEventListener('click', (e) => {
    const act = e.target.closest('[data-tour-act]')?.dataset.tourAct
    if (act === 'next') { tourIdx += 1; renderTour() } else if (act === 'prev') { tourIdx -= 1; renderTour() } else if (act === 'end') { closeTour(); body.classList.remove('sidebar-open') }
  })
  $('[data-tour-act="next"], [data-tour-act="end"]', layer)?.focus()
}

/* ---------------------------------------------------------------------------
   Atalhos e ações gerais
   --------------------------------------------------------------------------- */
function runAct (act) {
  if (act === 'tour') startTour()
  else if (act === 'map') openMap()
  else if (act === 'help') openHelp()
  else if (act === 'search') openPalette()
  else if (act === 'closeCallout') { store.set('calloutClosed', true); $('[data-hc-callout]')?.remove() }
}

// Abas de escopo (Meus / dos meus setores / Todos): a pílula desliza até a aba ativa.
function positionScopeIndicator () {
  const tabs = $('.scope-tabs')
  const ind = tabs && $('.scope-indicator', tabs)
  const act = tabs && $('.scope-tab.is-active', tabs)
  if (!ind || !act) return
  ind.style.left = act.offsetLeft + 'px'
  ind.style.width = act.offsetWidth + 'px'
}
// Janela de confirmação do protótipo (no lugar do confirm() do navegador).
function confirmBox ({ title, text, ok = 'Confirmar', danger = false, icon = 'fas fa-circle-question' }) {
  return new Promise((resolve) => {
    layers().insertAdjacentHTML('beforeend', `<div class="backdrop hc-modal-backdrop" data-modal-bd></div><div class="hc-modal${danger ? ' is-danger' : ''}" role="alertdialog" aria-modal="true" id="modalBox">
      <div class="m-ic"><i class="${esc(icon)}"></i></div><h3>${esc(title)}</h3><p>${esc(text)}</p>
      <div class="m-row"><button type="button" class="btn btn-secondary" data-m="0">Cancelar</button><button type="button" class="btn ${danger ? 'btn-danger' : 'btn-primary'}" data-m="1">${esc(ok)}</button></div></div>`)
    const box = $('#modalBox'); const bd = $('[data-modal-bd]')
    const key = (e) => { if (e.key === 'Escape') { e.stopPropagation(); done(false) } }
    const done = (v) => { box.remove(); bd.remove(); document.removeEventListener('keydown', key, true); resolve(v) }
    document.addEventListener('keydown', key, true)
    bd.addEventListener('click', () => done(false))
    box.querySelectorAll('[data-m]').forEach((b) => b.addEventListener('click', () => done(b.dataset.m === '1')))
    $('[data-m="1"]', box).focus()
  })
}
// Assunto do chamado: mostra descrição, prazo e responsáveis da opção escolhida.
document.addEventListener('change', (e) => {
  const select = e.target.closest('select[data-resp-info]'); if (!select) return
  const box = document.getElementById(select.dataset.respInfo); if (!box) return
  const option = select.options[select.selectedIndex]
  box.hidden = !option || !option.value
  if (!box.hidden) ['description', 'deadline', 'users'].forEach((k) => { const el = $(`[data-field="${k}"]`, box); if (el) el.textContent = option.dataset[k] || '' })
})

document.addEventListener('submit', async (e) => {
  const form = e.target.closest('form[data-hc-confirm]')
  if (!form || form.dataset.hcConfirmed) return
  e.preventDefault()
  let opts = {}
  try { opts = JSON.parse(form.dataset.hcConfirm) } catch { opts = { title: form.dataset.hcConfirm } }
  if (await confirmBox(opts)) { form.dataset.hcConfirmed = '1'; form.requestSubmit ? form.requestSubmit() : form.submit() }
}, true)

document.addEventListener('click', (e) => {
  const copy = e.target.closest('[data-pg-copy]')
  if (copy) {
    e.preventDefault()
    navigator.clipboard?.writeText(copy.dataset.pgCopy).then(() => { copy.dataset.tip = 'Copiado!'; setTimeout(() => { copy.dataset.tip = 'Copiar' }, 1500) })
    return
  }
  const kept = e.target.closest('[data-pg-layer]')
  if (kept) { e.preventDefault(); openKept(kept.dataset.pgLayer); return }
  const detail = e.target.closest('[data-pg-detail]')
  if (detail) {
    e.preventDefault()
    const src = $(`#${detail.dataset.pgDetail}`)
    if (src) { closeTour(); hideFlyout(); hideTip(); rescueKept(); layers().innerHTML = src.textContent }
    return
  }
  if (e.target.closest('[data-close]')) { e.preventDefault(); closeLayers(); return }
  const act = e.target.closest('[data-act]')
  if (act) { e.preventDefault(); runAct(act.dataset.act) }
})
document.addEventListener('keydown', (e) => {
  const typing = e.target.closest('input, textarea, select, [contenteditable="true"]')
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); openPalette(); return }
  if (e.key === 'Escape') { closeLayers(); closeTour(); hideFlyout(); body.classList.remove('sidebar-open'); return }
  if (e.key === '?' && !typing && !layers().children.length) { e.preventDefault(); openHelp() }
})

// Números dos indicadores sobem do zero até o valor (o HTML já traz o valor final).
function countUp (el) {
  const to = Number(el.dataset.count)
  if (!motionOn() || !to) return
  const fmt = (n) => n.toLocaleString('pt-BR')
  const t0 = performance.now()
  const step = (t) => {
    const p = Math.min(1, (t - t0) / 900)
    el.textContent = fmt(Math.round(to * (1 - Math.pow(1 - p, 3))))
    if (p < 1) requestAnimationFrame(step)
  }
  el.textContent = '0'
  requestAnimationFrame(step)
}

function init () {
  if (!$('#appView')) return
  document.querySelectorAll('[data-count]').forEach(countUp)
  // A dica "Novo por aqui?" some depois do tour ou de fechada uma vez.
  if (store.get('tourSeen', false) || store.get('calloutClosed', false)) $('[data-hc-callout]')?.remove()
  positionScopeIndicator()
  initSidebar()
  initTopbar()
  $('#sbSearch')?.addEventListener('click', openPalette)
  $('#topSearch')?.addEventListener('click', openPalette)
  $('#helpBtn')?.addEventListener('click', () => openHelp())
  $('#openMap')?.addEventListener('click', openMap)
  window.addEventListener('resize', () => { positionScopeIndicator(); hideFlyout(); if (isDesktop()) body.classList.remove('sidebar-open') })
  // Primeiro acesso ao visual novo: oferece o tour uma vez (no computador).
  if (!store.get('tourSeen', false) && isDesktop()) setTimeout(startTour, 700)
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init)
else init()

/* ---------------------------------------------------------------------------
   Modais do Bootstrap: o conteúdo da página (.content) tem z-index próprio, então um modal
   desenhado dentro dele fica preso numa camada abaixo do fundo escuro (que o Bootstrap põe no
   <body>) e nada nele é clicável. Antes de abrir, o modal vai para o <body>; o que está dentro
   de um formulário fica onde está (os campos dele são enviados junto) e o CSS tira o z-index do
   .content enquanto houver modal aberto (body.modal-open).
   --------------------------------------------------------------------------- */
document.addEventListener('show.bs.modal', (e) => {
  const modal = e.target
  if (!modal.classList?.contains('modal') || modal.parentElement === body || modal.closest('form')) return
  body.appendChild(modal)
})
})()
