// Jellify desktop — shared chrome components (sidebar, topbar, player bar, right panel)

// ─── Window chrome: traffic lights + top bar ───────────────────────────
function TrafficLights() {
  return (
    <div style={{display:'flex', gap:8, alignItems:'center', padding:'0 4px'}}>
      <div style={{width:12, height:12, borderRadius:'50%', background:'#FF5F57', boxShadow:'inset 0 0 0 0.5px rgba(0,0,0,0.25)'}}/>
      <div style={{width:12, height:12, borderRadius:'50%', background:'#FEBC2E', boxShadow:'inset 0 0 0 0.5px rgba(0,0,0,0.25)'}}/>
      <div style={{width:12, height:12, borderRadius:'50%', background:'#28C840', boxShadow:'inset 0 0 0 0.5px rgba(0,0,0,0.25)'}}/>
    </div>
  );
}

function TopBar({ t, onBack, onForward, search, setSearch, crumbs }) {
  return (
    <div style={{
      height:44, display:'flex', alignItems:'center', gap:16,
      padding:'0 16px 0 14px',
      background:t.bg, borderBottom:`1px solid ${t.border}`,
      WebkitAppRegion:'drag', userSelect:'none', flexShrink:0,
    }}>
      <TrafficLights/>
      <div style={{display:'flex', gap:4, marginLeft:8, WebkitAppRegion:'no-drag'}}>
        <NavArrow icon="chevron-left" t={t} onClick={onBack}/>
        <NavArrow icon="chevron-right" t={t} onClick={onForward}/>
      </div>
      {crumbs && (
        <div style={{display:'flex', alignItems:'center', gap:6, fontSize:12, color:t.ink2, fontWeight:500}}>
          {crumbs.map((c, i) => (
            <React.Fragment key={i}>
              {i>0 && <Icon name="chevron-right" size={12} color={t.ink3}/>}
              <span style={{color: i === crumbs.length-1 ? t.ink : t.ink2, fontWeight: i === crumbs.length-1 ? 600 : 500}}>{c}</span>
            </React.Fragment>
          ))}
        </div>
      )}
      <div style={{flex:1}}/>
      <div style={{WebkitAppRegion:'no-drag', display:'flex', alignItems:'center', gap:10}}>
        <div style={{
          display:'flex', alignItems:'center', gap:8,
          background:t.surface, borderRadius:999, padding:'6px 12px',
          border:`1px solid ${t.border}`, width:260,
        }}>
          <Icon name="search" size={14} color={t.ink2}/>
          <input value={search||''} onChange={e=>setSearch && setSearch(e.target.value)}
            placeholder="Search your library"
            style={{flex:1, background:'transparent', border:'none', outline:'none',
              color:t.ink, fontFamily:FONT_FAMILY, fontSize:12, fontWeight:500}}/>
          <kbd style={{fontSize:10, color:t.ink3, fontWeight:600, fontFamily:FONT_FAMILY,
            padding:'2px 6px', borderRadius:4, background:t.surface2, border:`1px solid ${t.border}`}}>⌘K</kbd>
        </div>
        <IconBtn icon="bell" t={t}/>
        <div style={{
          width:28, height:28, borderRadius:999, background:`linear-gradient(135deg, ${t.primary}, ${t.accent})`,
          display:'flex', alignItems:'center', justifyContent:'center',
          color:'#fff', fontWeight:700, fontSize:11, letterSpacing:'-0.01em',
          boxShadow:'inset 0 0 0 0.5px rgba(255,255,255,0.2)',
        }}>sk</div>
      </div>
    </div>
  );
}

function NavArrow({ icon, t, onClick }) {
  return (
    <div onClick={onClick} style={{
      width:28, height:28, borderRadius:8, display:'flex', alignItems:'center', justifyContent:'center',
      color:t.ink2, cursor:'pointer', background:'transparent',
    }}
      onMouseEnter={e => { e.currentTarget.style.background = t.surface; e.currentTarget.style.color = t.ink; }}
      onMouseLeave={e => { e.currentTarget.style.background = 'transparent'; e.currentTarget.style.color = t.ink2; }}>
      <Icon name={icon} size={14}/>
    </div>
  );
}

function IconBtn({ icon, t, onClick, active, size=18 }) {
  return (
    <div onClick={onClick} style={{
      width:32, height:32, borderRadius:8, display:'flex', alignItems:'center', justifyContent:'center',
      color: active ? t.accent : t.ink2, cursor:'pointer',
      background: active ? t.surface2 : 'transparent',
      transition:'all 0.12s',
    }}
      onMouseEnter={e => { if (!active) e.currentTarget.style.background = t.surface; }}
      onMouseLeave={e => { if (!active) e.currentTarget.style.background = 'transparent'; }}>
      <Icon name={icon} size={size}/>
    </div>
  );
}

// ─── Sidebar ────────────────────────────────────────────────────────────
function Sidebar({ t, screen, setScreen, density }) {
  const compact = density === 'compact';
  const [playlistsOpen, setPlaylistsOpen] = React.useState(true);
  const nav = [
    { id:'home', icon:'home', label:'Home' },
    { id:'library', icon:'library', label:'Library' },
    { id:'search', icon:'search', label:'Search' },
    { id:'discover', icon:'compass', label:'Discover' },
    { id:'radio', icon:'radio', label:'Radio' },
  ];
  const library = [
    { id:'favorites', icon:'heart', label:'Favorites', count:214 },
    { id:'albums', icon:'album', label:'Albums', count:586 },
    { id:'artists', icon:'user', label:'Artists', count:312 },
    { id:'tracks', icon:'music', label:'All Tracks', count:4208 },
    { id:'downloads', icon:'download', label:'Downloads', count:148 },
  ];
  return (
    <div style={{
      width:252, background:t.bgAlt, borderRight:`1px solid ${t.border}`,
      display:'flex', flexDirection:'column', flexShrink:0,
      fontFamily:FONT_FAMILY,
    }}>
      {/* Brand */}
      <div style={{padding:'12px 18px 8px', display:'flex', alignItems:'center', gap:10}}>
        <div style={{
          width:30, height:30, borderRadius:8,
          background:`linear-gradient(135deg, ${t.teal} 0%, ${t.primary} 100%)`,
          display:'flex', alignItems:'center', justifyContent:'center',
          boxShadow:'inset 0 0 0 0.5px rgba(255,255,255,0.25), 0 4px 10px rgba(87,233,201,0.2)',
          fontSize:16,
        }}>🪼</div>
        <div>
          <div style={{fontSize:15, fontWeight:800, color:t.ink, letterSpacing:'-0.02em', fontStyle:'italic'}}>Jellify</div>
          <div style={{fontSize:9, fontWeight:600, color:t.ink3, textTransform:'uppercase', letterSpacing:'0.08em', marginTop:-1}}>Desktop</div>
        </div>
      </div>

      <div style={{padding:'4px 10px'}}>
        {nav.map(n => (
          <NavItem key={n.id} {...n} t={t} compact={compact}
            active={screen===n.id} onClick={()=>setScreen(n.id)}/>
        ))}
      </div>

      <div style={{padding:'10px 18px 6px', fontSize:10, fontWeight:700, color:t.ink3,
        textTransform:'uppercase', letterSpacing:'0.08em'}}>Your Library</div>
      <div style={{padding:'0 10px'}}>
        {library.map(n => (
          <NavItem key={n.id} {...n} t={t} compact={compact}
            active={screen===n.id} onClick={()=>setScreen(n.id)}/>
        ))}
      </div>

      <div onClick={()=>setPlaylistsOpen(!playlistsOpen)} style={{
        padding:'12px 18px 6px', fontSize:10, fontWeight:700, color:t.ink3,
        textTransform:'uppercase', letterSpacing:'0.08em',
        display:'flex', alignItems:'center', justifyContent:'space-between', cursor:'pointer',
      }}>
        <span>Playlists</span>
        <div style={{display:'flex', gap:4}}>
          <Icon name="plus" size={12} color={t.ink3}/>
          <Icon name={playlistsOpen ? 'chevron-down' : 'chevron-right'} size={12} color={t.ink3}/>
        </div>
      </div>
      {playlistsOpen && (
        <div style={{padding:'0 10px', flex:1, overflowY:'auto', minHeight:0}}>
          {PLAYLISTS.map((p, i) => (
            <div key={i} onClick={()=>setScreen('playlist:'+p.seed)} style={{
              display:'flex', alignItems:'center', gap:10,
              padding: compact ? '5px 8px' : '7px 8px', borderRadius:6, cursor:'pointer',
              color: screen==='playlist:'+p.seed ? t.ink : t.ink2,
              background: screen==='playlist:'+p.seed ? t.surface2 : 'transparent',
            }}
              onMouseEnter={e => { if (screen!=='playlist:'+p.seed) e.currentTarget.style.background = t.surface; }}
              onMouseLeave={e => { if (screen!=='playlist:'+p.seed) e.currentTarget.style.background = 'transparent'; }}>
              <Artwork seed={p.seed} size={compact? 22 : 28} radius={4} style={{boxShadow:'none'}}/>
              <div style={{flex:1, minWidth:0}}>
                <div style={{fontSize:12, fontWeight:600, whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>{p.title}</div>
                {!compact && <div style={{fontSize:10, color:t.ink3, fontWeight:500, marginTop:-1}}>{p.count} tracks</div>}
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Server + settings footer */}
      <div style={{
        padding:'10px 14px', borderTop:`1px solid ${t.border}`,
        display:'flex', alignItems:'center', gap:10,
      }}>
        <div style={{width:8, height:8, borderRadius:'50%', background:t.teal,
          boxShadow:`0 0 8px ${t.teal}`, flexShrink:0}}/>
        <div style={{flex:1, minWidth:0}}>
          <div style={{fontSize:11, fontWeight:700, color:t.ink, whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>jellyfin.home.arpa</div>
          <div style={{fontSize:10, color:t.ink3, fontWeight:500}}>Connected · 4,208 tracks</div>
        </div>
        <div style={{color:t.ink3, cursor:'pointer'}} onClick={()=>setScreen('settings')}>
          <Icon name="settings" size={14}/>
        </div>
      </div>
    </div>
  );
}

function NavItem({ icon, label, count, t, compact, active, onClick }) {
  const [hover, setHover] = React.useState(false);
  return (
    <div onClick={onClick}
      onMouseEnter={()=>setHover(true)} onMouseLeave={()=>setHover(false)}
      style={{
        display:'flex', alignItems:'center', gap:10,
        padding: compact ? '6px 10px' : '8px 10px', borderRadius:8,
        cursor:'pointer',
        color: active ? t.ink : (hover ? t.ink : t.ink2),
        background: active ? t.surface2 : (hover ? t.surface : 'transparent'),
        position:'relative',
      }}>
      {active && <div style={{position:'absolute', left:0, top:6, bottom:6, width:3,
        borderRadius:'0 2px 2px 0', background:t.accent}}/>}
      <Icon name={icon} size={16} color={active ? t.accent : 'currentColor'}/>
      <div style={{flex:1, fontSize:13, fontWeight: active ? 700 : 600}}>{label}</div>
      {count !== undefined && <div style={{fontSize:10, color:t.ink3, fontWeight:600}}>{count.toLocaleString()}</div>}
    </div>
  );
}

// ─── Player Bar (bottom) ───────────────────────────────────────────────
function PlayerBar({ t, track, playing, onToggle, progress, setProgress, volume, setVolume, onOpenQueue, queueOpen, onOpenPlayer }) {
  if (!track) return null;
  return (
    <div style={{
      height:78, background:t.bgAlt, borderTop:`1px solid ${t.border}`,
      display:'flex', alignItems:'center', padding:'0 16px',
      fontFamily:FONT_FAMILY, flexShrink:0, gap:16,
    }}>
      {/* Left: artwork + meta */}
      <div style={{display:'flex', alignItems:'center', gap:12, minWidth:0, width:280}}>
        <Artwork seed={track.title} size={54} radius={6} onClick={onOpenPlayer}/>
        <div style={{minWidth:0, flex:1}}>
          <div style={{fontSize:13, fontWeight:700, color:t.ink, whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>{track.title}</div>
          <div style={{fontSize:11, color:t.ink2, fontWeight:500, whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>
            {track.artist} · <span style={{color:t.ink3}}>{track.album}</span>
          </div>
        </div>
        <IconBtn icon="heart" t={t} active={track.fav} size={16}/>
      </div>

      {/* Center: transport + scrubber */}
      <div style={{flex:1, display:'flex', flexDirection:'column', alignItems:'center', gap:4, minWidth:0, maxWidth:640}}>
        <div style={{display:'flex', alignItems:'center', gap:14}}>
          <IconBtn icon="shuffle" t={t} size={16}/>
          <IconBtn icon="skip-prev" t={t} size={18}/>
          <div onClick={onToggle} style={{
            width:36, height:36, borderRadius:'50%',
            background: t.ink,
            display:'flex', alignItems:'center', justifyContent:'center', cursor:'pointer',
            boxShadow:'0 2px 8px rgba(0,0,0,0.25)',
          }}>
            <Icon name={playing ? 'pause' : 'play'} size={16} color={t.bg} fill/>
          </div>
          <IconBtn icon="skip-next" t={t} size={18}/>
          <IconBtn icon="repeat" t={t} size={16}/>
        </div>
        <div style={{display:'flex', alignItems:'center', gap:10, width:'100%'}}>
          <div style={{fontSize:10, color:t.ink3, fontWeight:600, minWidth:32, textAlign:'right', fontVariantNumeric:'tabular-nums'}}>
            {formatTime(progress * durationSec(track.duration))}
          </div>
          <div style={{flex:1, height:4, background:t.surface2, borderRadius:2, position:'relative', cursor:'pointer'}}
            onClick={e => {
              const r = e.currentTarget.getBoundingClientRect();
              setProgress(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)));
            }}>
            <div style={{width:`${progress*100}%`, height:'100%', background:t.ink, borderRadius:2}}/>
            <div style={{position:'absolute', left:`${progress*100}%`, top:'50%', transform:'translate(-50%, -50%)',
              width:10, height:10, borderRadius:'50%', background:t.ink, opacity:0,
              transition:'opacity 0.15s'}} className="scrubber-thumb"/>
          </div>
          <div style={{fontSize:10, color:t.ink3, fontWeight:600, minWidth:32, fontVariantNumeric:'tabular-nums'}}>{track.duration}</div>
        </div>
      </div>

      {/* Right: volume + queue */}
      <div style={{display:'flex', alignItems:'center', gap:6, width:280, justifyContent:'flex-end'}}>
        <IconBtn icon="mix" t={t} size={16}/>
        <IconBtn icon="queue" t={t} size={16} active={queueOpen} onClick={onOpenQueue}/>
        <IconBtn icon="cast" t={t} size={16}/>
        <Icon name={volume > 0 ? 'volume' : 'volume-off'} size={16} color={t.ink2} style={{marginLeft:4}}/>
        <div style={{width:80, height:4, background:t.surface2, borderRadius:2, position:'relative', cursor:'pointer'}}
          onClick={e => {
            const r = e.currentTarget.getBoundingClientRect();
            setVolume(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)));
          }}>
          <div style={{width:`${volume*100}%`, height:'100%', background:t.ink2, borderRadius:2}}/>
        </div>
        <IconBtn icon="fullscreen" t={t} size={14} onClick={onOpenPlayer}/>
      </div>
    </div>
  );
}

function durationSec(d) {
  const parts = (d||'0:00').split(':').map(Number);
  return parts.length === 2 ? parts[0]*60 + parts[1] : parts[0]*3600 + parts[1]*60 + parts[2];
}
function formatTime(s) {
  s = Math.floor(s || 0);
  const m = Math.floor(s/60); const ss = s%60;
  if (m >= 60) { const h = Math.floor(m/60); return `${h}:${String(m%60).padStart(2,'0')}:${String(ss).padStart(2,'0')}`; }
  return `${m}:${String(ss).padStart(2,'0')}`;
}

Object.assign(window, { TrafficLights, TopBar, NavArrow, IconBtn, Sidebar, NavItem, PlayerBar, durationSec, formatTime });
