import { useEffect, useMemo, useState, type ReactNode } from 'react'
import icon from '../../resources/icon.png'
import hero from '../screenshots/columns.png'
import { groups, shortcuts, type Shot } from './features'

const repo = 'https://github.com/hunghg255/mycode'

// rich renders the two bits of Markdown the feature text uses: **bold** for UI
// names and `code` for keys, paths and settings.
function rich(text: string): ReactNode[] {
  return text.split(/(\*\*[^*]+\*\*|`[^`]+`)/g).map((part, i) => {
    if (part.startsWith('**')) return <b key={i}>{part.slice(2, -2)}</b>
    if (part.startsWith('`')) return <code key={i}>{part.slice(1, -1)}</code>
    return part
  })
}

type Theme = 'light' | 'dark' | ''

function useTheme(): [Theme, () => void] {
  const [theme, setTheme] = useState<Theme>(() => {
    try {
      return (localStorage.getItem('theme') as Theme) || ''
    } catch {
      return ''
    }
  })
  useEffect(() => {
    const root = document.documentElement
    if (theme) root.dataset.theme = theme
    else delete root.dataset.theme
    try {
      localStorage.setItem('theme', theme)
    } catch {
      // Storage may be blocked; the theme then lasts for this visit.
    }
  }, [theme])
  const toggle = () => {
    const dark = theme ? theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches
    setTheme(dark ? 'light' : 'dark')
  }
  return [theme, toggle]
}

function Lightbox({ shot, onClose }: { shot: Shot; onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    addEventListener('keydown', onKey)
    return () => removeEventListener('keydown', onKey)
  }, [onClose])
  return (
    <div className="lightbox" onClick={onClose} role="dialog" aria-label={shot.alt}>
      <img src={shot.src} alt={shot.alt} />
      <p>{shot.caption}</p>
    </div>
  )
}

export default function App() {
  const [, toggleTheme] = useTheme()
  const [query, setQuery] = useState('')
  const [shot, setShot] = useState<Shot | null>(null)

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return groups
    return groups
      .map((g) => ({
        ...g,
        features: g.title.toLowerCase().includes(q)
          ? g.features
          : g.features.filter((f) => (f.title + ' ' + f.text).toLowerCase().includes(q)),
      }))
      .filter((g) => g.features.length > 0)
  }, [query])

  const count = groups.reduce((n, g) => n + g.features.length, 0)

  return (
    <>
      <header className="topbar">
        <a className="brand" href="#top">
          <img src={icon} alt="" width={28} height={28} />
          MyCode
        </a>
        <nav>
          <a href="#features">Features</a>
          <a href="#shortcuts">Shortcuts</a>
          <a href="#start">Get started</a>
          <a href={repo}>GitHub</a>
        </nav>
        <button className="theme" onClick={toggleTheme} aria-label="Toggle light and dark">
          ◐
        </button>
      </header>

      <main id="top">
        <section className="hero">
          <img className="hero-icon" src={icon} alt="MyCode icon" width={96} height={96} />
          <h1>A small, fast code editor written in Go</h1>
          <p className="tagline">
            MyCode draws a native UI on the GPU with <a href="https://github.com/egoist/mygo">MyGo</a>. No webview, no
            Electron, and the packaged app is about 18 MB.
          </p>
          <div className="cta">
            <a className="button primary" href="#start">
              Get started
            </a>
            <a className="button" href={`${repo}/releases`}>
              Download
            </a>
          </div>
          <ul className="facts">
            <li>
              <b>~18 MB</b> packaged app
            </li>
            <li>
              <b>GPU</b> native rendering
            </li>
            <li>
              <b>macOS · Linux · Windows</b>
            </li>
            <li>
              <b>{count}+</b> features
            </li>
          </ul>
          <button className="hero-shot" onClick={() => setShot({ src: hero, alt: 'MyCode', caption: 'MyCode' })}>
            <img src={hero} alt="MyCode with two columns of Go source" />
          </button>
        </section>

        <section id="features" className="features">
          <div className="features-head">
            <h2>Everything in the editor</h2>
            <input
              type="search"
              placeholder="Filter features… (git, terminal, preview)"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              aria-label="Filter features"
            />
          </div>
          <nav className="chips">
            {groups.map((g) => (
              <a key={g.id} href={`#${g.id}`}>
                <span aria-hidden>{g.icon}</span> {g.title}
              </a>
            ))}
          </nav>

          {shown.length === 0 && <p className="empty">No feature matches “{query}”.</p>}

          {shown.map((g) => (
            <article key={g.id} id={g.id} className="group">
              <div className="group-head">
                <span className="group-icon" aria-hidden>
                  {g.icon}
                </span>
                <div>
                  <h3>{g.title}</h3>
                  <p>{rich(g.lead)}</p>
                </div>
              </div>
              <div className="cards">
                {g.features.map((f) => (
                  <div key={f.title} className="card">
                    <h4>{f.title}</h4>
                    <p>{rich(f.text)}</p>
                  </div>
                ))}
              </div>
              {!query && g.shots && (
                <div className={`shots n${g.shots.length}`}>
                  {g.shots.map((s) => (
                    <figure key={s.src}>
                      <button onClick={() => setShot(s)}>
                        <img src={s.src} alt={s.alt} />
                      </button>
                      <figcaption>{s.caption}</figcaption>
                    </figure>
                  ))}
                </div>
              )}
            </article>
          ))}
        </section>

        <section id="shortcuts" className="shortcuts">
          <h2>Keyboard shortcuts</h2>
          <p className="muted">
            On Windows and Linux, ⌘ is Ctrl. Every shortcut can be changed in <code>keybindings.json</code>.
          </p>
          <div className="table">
            {shortcuts.map(([keys, action]) => (
              <div key={keys} className="row">
                <kbd>{keys}</kbd>
                <span>{action}</span>
              </div>
            ))}
          </div>
        </section>

        <section id="start" className="start">
          <h2>Get started</h2>
          <div className="steps">
            <div>
              <h4>1. Requirements</h4>
              <p>macOS 13 or later and Go 1.27 or later. MyCode also builds for Linux and Windows.</p>
            </div>
            <div>
              <h4>2. Run from source</h4>
              <pre>
                <code>{`git clone ${repo}
cd mycode
go run ./cmd/mayoi ~/some/project`}</code>
              </pre>
            </div>
            <div>
              <h4>3. Build the app</h4>
              <pre>
                <code>{`go tool mygo build
# build/darwin-arm64/MyCode.app and a .dmg`}</code>
              </pre>
            </div>
            <div>
              <h4>4. Open from a shell</h4>
              <p>
                Choose <b>File → Install 'mycode' Command</b> on macOS, then run <code>mycode .</code> or{' '}
                <code>mycode &lt;file&gt;</code>. On Windows the installed app sets it up by itself.
              </p>
            </div>
          </div>
        </section>
      </main>

      <footer>
        <p>
          MyCode by <a href="https://github.com/hunghg255">hunghg255</a>, from{' '}
          <a href="https://github.com/sorrycc/Mayoi">Mayoi</a> by chencheng. Released under the{' '}
          <a href={`${repo}/blob/main/LICENSE`}>MIT license</a>.
        </p>
      </footer>

      {shot && <Lightbox shot={shot} onClose={() => setShot(null)} />}
    </>
  )
}
