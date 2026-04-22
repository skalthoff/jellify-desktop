// Jellify desktop — right panel (now playing / queue) + full-screen player + tweaks

// ─── Right Panel: Now Playing ──────────────────────────────────────────
function RightPanel({ t, mode, setMode, track, playing, onPlay, onClose }) {
  if (!track) return null;
  return (
    <div style={{
      width:340, background:t.bgAlt, borderLeft:`1px solid ${t.border}`,
      display:'flex', flexDirection:'column', flexShrink:0,
      fontFamily:FONT_FAMILY,
    }}>
      <div style={{
        display:'flex', alignItems:'center', justifyContent:'space-between',
        padding:'14px 16px', borderBottom:`1px solid ${t.border}`,
      }}>
        <div style={{display:'flex', gap:4, background:t.surface, padding:3, borderRadius:8, border:`1px solid ${t.border}`}}>
          <TabBtn label="Now Playing" active={mode==='now-playing'} onClick={()=>setMode('now-playing')} t={t}/>
          <TabBtn label="Queue" active={mode==='queue'} onClick={()=>setMode('queue')} t={t}/>
          <TabBtn label="Lyrics" active={mode==='lyrics'} onClick={()=>setMode('lyrics')} t={t}/>
        </div>
        <IconBtn icon="close" t={t} size={14} onClick={onClose}/>
      </div>

      <div style={{flex:1, overflowY:'auto'}}>
        {mode === 'now-playing' && <NowPlayingPanel t={t} track={track} playing={playing}/>}
        {mode === 'queue' && <QueuePanel t={t} onPlay={onPlay}/>}
        {mode === 'lyrics' && <LyricsPanel t={t} track={track}/>}
      </div>
    </div>
  );
}

function TabBtn({ label, active, onClick, t }) {
  return (
    <div onClick={onClick} style={{
      padding:'5px 10px', borderRadius:5, fontSize:11, fontWeight:700,
      color: active ? t.bg : t.ink2,
      background: active ? t.ink : 'transparent',
      cursor:'pointer', letterSpacing:'-0.01em',
    }}>{label}</div>
  );
}

function NowPlayingPanel({ t, track, playing }) {
  return (
    <div style={{padding:16}}>
      <Artwork seed={track.title} size="100%" radius={10} style={{width:'100%', aspectRatio:'1/1', height:'auto'}}/>
      <div style={{marginTop:16, display:'flex', alignItems:'flex-start', justifyContent:'space-between', gap:10}}>
        <div style={{minWidth:0}}>
          <div style={{fontSize:18, fontWeight:800, color:t.ink, letterSpacing:'-0.02em',
            whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>{track.title}</div>
          <div style={{fontSize:13, color:t.ink2, fontWeight:500, marginTop:2,
            whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>{track.artist}</div>
          <div style={{fontSize:11, color:t.ink3, fontWeight:500, marginTop:2,
            whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>{track.album}</div>
        </div>
        <IconBtn icon="heart" t={t} active={track.fav}/>
      </div>

      {/* About this track */}
      <div style={{
        marginTop:18, padding:14, background:t.surface, borderRadius:10,
        border:`1px solid ${t.border}`,
      }}>
        <div style={{fontSize:10, fontWeight:700, color:t.ink3, textTransform:'uppercase', letterSpacing:'0.08em', marginBottom:10}}>About this track</div>
        <Row t={t} label="Album" value={track.album}/>
        <Row t={t} label="Released" value={track.year || '2020'}/>
        <Row t={t} label="Duration" value={track.duration}/>
        <Row t={t} label="Plays" value={(track.plays||142).toLocaleString()}/>
        <Row t={t} label="Bitrate" value="FLAC · 1,411 kbps"/>
        <Row t={t} label="Size" value="28.4 MB"/>
      </div>

      {/* Credits */}
      <div style={{marginTop:14, padding:14, background:t.surface, borderRadius:10, border:`1px solid ${t.border}`}}>
        <div style={{fontSize:10, fontWeight:700, color:t.ink3, textTransform:'uppercase', letterSpacing:'0.08em', marginBottom:10}}>Credits</div>
        <Row t={t} label="Written by" value={track.artist}/>
        <Row t={t} label="Produced by" value={track.artist}/>
        <Row t={t} label="Label" value="Kranky"/>
      </div>

      <div style={{marginTop:14, fontSize:11, color:t.ink3, fontWeight:500, textAlign:'center', fontStyle:'italic'}}>
        <em>you've played this {track.plays || 142} times. maybe try something new?</em>
      </div>
    </div>
  );
}

function Row({ t, label, value }) {
  return (
    <div style={{display:'flex', justifyContent:'space-between', alignItems:'center', padding:'6px 0',
      borderBottom:`1px solid ${t.border}`, fontSize:12}}>
      <div style={{color:t.ink2, fontWeight:500}}>{label}</div>
      <div style={{color:t.ink, fontWeight:600, textAlign:'right'}}>{value}</div>
    </div>
  );
}

function QueuePanel({ t, onPlay }) {
  return (
    <div style={{padding:'12px 12px 24px'}}>
      <div style={{padding:'6px 10px 10px', display:'flex', justifyContent:'space-between'}}>
        <div style={{fontSize:10, fontWeight:700, color:t.ink3, textTransform:'uppercase', letterSpacing:'0.08em'}}>Now Playing</div>
      </div>
      <div style={{padding:'10px 12px', borderRadius:8, background:t.surface2, display:'flex', alignItems:'center', gap:12, marginBottom:16}}>
        <Artwork seed="Yona" size={40} radius={5} style={{boxShadow:'none'}}/>
        <div style={{flex:1, minWidth:0}}>
          <div style={{fontSize:13, fontWeight:700, color:t.accent, whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>Yona</div>
          <div style={{fontSize:11, color:t.ink2, fontWeight:500}}>Saloli</div>
        </div>
        <Equalizer color={t.accent}/>
      </div>
      <div style={{padding:'0 10px 10px', display:'flex', justifyContent:'space-between', alignItems:'center'}}>
        <div style={{fontSize:10, fontWeight:700, color:t.ink3, textTransform:'uppercase', letterSpacing:'0.08em'}}>Up Next · From "The Deep End"</div>
        <div style={{fontSize:10, fontWeight:600, color:t.ink2, cursor:'pointer'}}>Clear</div>
      </div>
      {QUEUE_UP_NEXT.map((tr, i) => (
        <div key={i} onClick={()=>onPlay(tr)} style={{
          display:'flex', alignItems:'center', gap:12, padding:'8px 10px', borderRadius:6, cursor:'pointer',
        }}
          onMouseEnter={e=>e.currentTarget.style.background=t.surface}
          onMouseLeave={e=>e.currentTarget.style.background='transparent'}>
          <div style={{width:18, fontSize:10, color:t.ink3, fontWeight:600, textAlign:'center'}}>{i+1}</div>
          <Artwork seed={tr.title} size={34} radius={4} style={{boxShadow:'none'}}/>
          <div style={{flex:1, minWidth:0}}>
            <div style={{fontSize:12, fontWeight:600, color:t.ink, whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>{tr.title}</div>
            <div style={{fontSize:10, color:t.ink2, fontWeight:500}}>{tr.artist}</div>
          </div>
          <div style={{fontSize:10, color:t.ink3, fontWeight:500, fontVariantNumeric:'tabular-nums'}}>{tr.duration}</div>
        </div>
      ))}
    </div>
  );
}

function LyricsPanel({ t, track }) {
  const lines = [
    { time:'0:08', text:'soft tide at the edge of a wire' },
    { time:'0:18', text:'hum like the rain on a station' },
    { time:'0:34', text:'you set the room to glow' },
    { time:'0:52', text:'and we let the synth decide' },
    { time:'1:12', text:'yona, yona,', active:true },
    { time:'1:24', text:'a blue room of yours and mine' },
    { time:'1:44', text:'we stayed up until it passed' },
    { time:'2:02', text:'and the morning came soft as jam' },
    { time:'2:22', text:'yona, yona, never mind the time' },
  ];
  return (
    <div style={{padding:'20px 20px 40px', fontSize:16, lineHeight:1.6, fontWeight:600}}>
      <div style={{fontSize:10, fontWeight:700, color:t.ink3, textTransform:'uppercase', letterSpacing:'0.08em', marginBottom:14}}>Lyrics · synced</div>
      {lines.map((l, i) => (
        <div key={i} style={{
          color: l.active ? t.ink : t.ink3,
          fontSize: l.active ? 20 : 15,
          fontWeight: l.active ? 800 : 600,
          letterSpacing: l.active ? '-0.02em' : '-0.01em',
          padding:'6px 0',
          transition:'all 0.2s',
        }}>{l.text}</div>
      ))}
      <div style={{marginTop:20, fontSize:10, color:t.ink3, fontStyle:'italic'}}>lyrics from Jellyfin plugin · crowd-sourced</div>
    </div>
  );
}

// ─── Full Screen Player ────────────────────────────────────────────────
function FullPlayer({ t, track, playing, onToggle, onClose, progress, setProgress }) {
  return (
    <div style={{
      position:'absolute', inset:0, zIndex:200,
      background:t.bg, fontFamily:FONT_FAMILY, color:t.ink, overflow:'hidden',
      animation:'playerIn 0.4s cubic-bezier(0.22,1,0.36,1)',
    }}>
      <style>{`@keyframes playerIn { from { transform:translateY(40px); opacity:0 } to { transform:translateY(0); opacity:1 } }`}</style>
      {/* Ambient artwork wash */}
      <div style={{position:'absolute', inset:0,
        background:`radial-gradient(ellipse at 30% 20%, ${t.primary}33, transparent 50%),
                    radial-gradient(ellipse at 80% 90%, ${t.accent}33, transparent 55%)`,
        filter:'blur(20px)'}}/>
      <div style={{position:'relative', height:'100%', display:'flex', flexDirection:'column'}}>
        {/* Chrome */}
        <div style={{height:44, display:'flex', alignItems:'center', padding:'0 16px', gap:14, WebkitAppRegion:'drag'}}>
          <TrafficLights/>
          <div style={{flex:1, textAlign:'center', fontSize:11, fontWeight:700, color:t.ink2,
            textTransform:'uppercase', letterSpacing:'0.1em'}}>Playing from <span style={{color:t.ink}}>{track.album}</span></div>
          <div style={{WebkitAppRegion:'no-drag'}}>
            <IconBtn icon="minimize" t={t} onClick={onClose}/>
          </div>
        </div>

        <div style={{flex:1, display:'grid', gridTemplateColumns:'1fr 1fr', padding:'20px 64px 32px', gap:48, alignItems:'center'}}>
          {/* Artwork */}
          <div style={{display:'flex', justifyContent:'flex-end'}}>
            <div style={{position:'relative'}}>
              <Artwork seed={track.title} size={420} radius={16}
                style={{boxShadow:'0 30px 80px rgba(0,0,0,0.55)'}}/>
              {/* Record shadow */}
              <div style={{
                position:'absolute', right:-80, top:10, width:400, height:400, borderRadius:'50%',
                background:`conic-gradient(from 0deg, #111 0%, #222 15%, #111 30%, #222 45%, #111 60%)`,
                boxShadow:'0 20px 40px rgba(0,0,0,0.5), inset 0 0 40px rgba(0,0,0,0.8)',
                zIndex:-1,
                animation: playing ? 'vinyl 8s linear infinite' : 'none',
              }}>
                <div style={{position:'absolute', inset:'40%', borderRadius:'50%',
                  background:`linear-gradient(135deg, ${t.primary}, ${t.accent})`,
                  boxShadow:'inset 0 0 20px rgba(0,0,0,0.4)'}}/>
                <div style={{position:'absolute', inset:'47%', borderRadius:'50%', background:'#000'}}/>
              </div>
              <style>{`@keyframes vinyl { to { transform:rotate(360deg) } }`}</style>
            </div>
          </div>

          {/* Info + controls */}
          <div style={{display:'flex', flexDirection:'column', gap:28, maxWidth:460}}>
            <div>
              <div style={{fontSize:11, fontWeight:700, color:t.ink2, textTransform:'uppercase', letterSpacing:'0.12em', marginBottom:10}}>Now Playing</div>
              <div style={{fontSize:56, fontWeight:900, color:t.ink, letterSpacing:'-0.035em', lineHeight:1}}>{track.title}</div>
              <div style={{fontSize:20, color:t.ink2, fontWeight:600, marginTop:12, letterSpacing:'-0.01em'}}>{track.artist}</div>
              <div style={{fontSize:14, color:t.ink3, fontWeight:500, marginTop:4}}>{track.album} · {track.year || 2020}</div>
            </div>

            {/* Progress */}
            <div>
              <div style={{height:5, background:t.surface2, borderRadius:3, position:'relative', cursor:'pointer'}}
                onClick={e => {
                  const r = e.currentTarget.getBoundingClientRect();
                  setProgress(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)));
                }}>
                <div style={{width:`${progress*100}%`, height:'100%',
                  background:`linear-gradient(90deg, ${t.primary}, ${t.accent})`, borderRadius:3}}/>
                <div style={{position:'absolute', left:`${progress*100}%`, top:'50%', transform:'translate(-50%, -50%)',
                  width:14, height:14, borderRadius:'50%', background:t.ink,
                  boxShadow:'0 2px 8px rgba(0,0,0,0.4)'}}/>
              </div>
              <div style={{display:'flex', justifyContent:'space-between', marginTop:8, fontSize:11,
                color:t.ink2, fontWeight:600, fontVariantNumeric:'tabular-nums'}}>
                <div>{formatTime(progress * durationSec(track.duration))}</div>
                <div>-{formatTime((1-progress) * durationSec(track.duration))}</div>
              </div>
            </div>

            <div style={{display:'flex', alignItems:'center', gap:24}}>
              <IconBtn icon="shuffle" t={t} size={20}/>
              <IconBtn icon="skip-prev" t={t} size={28}/>
              <div onClick={onToggle} style={{
                width:72, height:72, borderRadius:'50%',
                background:`linear-gradient(135deg, ${t.primary}, ${t.accent})`,
                display:'flex', alignItems:'center', justifyContent:'center', cursor:'pointer',
                boxShadow:`0 20px 40px ${t.primary}55, inset 0 0 0 0.5px rgba(255,255,255,0.2)`,
              }}>
                <Icon name={playing ? 'pause' : 'play'} size={28} color="#fff" fill/>
              </div>
              <IconBtn icon="skip-next" t={t} size={28}/>
              <IconBtn icon="repeat" t={t} size={20}/>
            </div>

            <div style={{display:'flex', gap:20, alignItems:'center'}}>
              <IconBtn icon="heart" t={t} size={18} active={track.fav}/>
              <IconBtn icon="download" t={t} size={18}/>
              <IconBtn icon="queue" t={t} size={18}/>
              <IconBtn icon="cast" t={t} size={18}/>
              <IconBtn icon="mix" t={t} size={18}/>
              <IconBtn icon="dots-v" t={t} size={18}/>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

// ─── Tweaks panel ──────────────────────────────────────────────────────
function TweaksPanel({ open, settings, setSettings, t, onClose }) {
  if (!open) return null;
  const set = (k, v) => setSettings({...settings, [k]: v});
  return (
    <div style={{
      position:'fixed', right:20, bottom:100, width:280, zIndex:500,
      background:t.bgAlt, border:`1px solid ${t.borderStrong}`,
      borderRadius:14, padding:16, fontFamily:FONT_FAMILY,
      boxShadow:'0 24px 64px rgba(0,0,0,0.55)',
    }}>
      <div style={{display:'flex', justifyContent:'space-between', alignItems:'center', marginBottom:14}}>
        <div style={{fontSize:13, fontWeight:800, color:t.ink, letterSpacing:'-0.01em'}}>Tweaks</div>
        <IconBtn icon="close" t={t} size={12} onClick={onClose}/>
      </div>

      <TweakGroup label="Theme" t={t}>
        <div style={{display:'grid', gridTemplateColumns:'repeat(5, 1fr)', gap:6}}>
          {['purple','ocean','forest','sunset','peanut'].map(th => (
            <div key={th} onClick={()=>set('theme', th)} style={{
              height:34, borderRadius:7, cursor:'pointer',
              background: th==='purple' ? 'linear-gradient(135deg,#0C0622,#887BFF)' :
                          th==='ocean' ? 'linear-gradient(135deg,#041025,#4B7DD7)' :
                          th==='forest' ? 'linear-gradient(135deg,#081A14,#57E9C9)' :
                          th==='sunset' ? 'linear-gradient(135deg,#24060F,#FF6625)' :
                                          'linear-gradient(135deg,#1C140A,#D4A360)',
              border: settings.theme===th ? `2px solid ${t.ink}` : `1px solid ${t.border}`,
              boxShadow: settings.theme===th ? `0 0 0 2px ${t.accent}55` : 'none',
            }}/>
          ))}
        </div>
        <div style={{display:'flex', justifyContent:'space-between', marginTop:4, fontSize:9, color:t.ink3, fontWeight:600}}>
          {['Purple','Ocean','Forest','Sunset','Peanut'].map(x => <span key={x}>{x}</span>)}
        </div>
      </TweakGroup>

      <TweakGroup label="Mode" t={t}>
        <div style={{display:'flex', gap:6}}>
          {['dark','oled'].map(m => (
            <div key={m} onClick={()=>set('mode', m)} style={{
              flex:1, padding:'8px 10px', fontSize:11, fontWeight:700,
              textAlign:'center', borderRadius:7, cursor:'pointer',
              background: settings.mode===m ? t.ink : t.surface,
              color: settings.mode===m ? t.bg : t.ink2,
              textTransform:'capitalize',
              border:`1px solid ${t.border}`,
            }}>{m}</div>
          ))}
          {settings.theme === 'purple' && (
            <div onClick={()=>set('mode', 'light')} style={{
              flex:1, padding:'8px 10px', fontSize:11, fontWeight:700,
              textAlign:'center', borderRadius:7, cursor:'pointer',
              background: settings.mode==='light' ? t.ink : t.surface,
              color: settings.mode==='light' ? t.bg : t.ink2,
              border:`1px solid ${t.border}`,
            }}>Light</div>
          )}
        </div>
      </TweakGroup>

      <TweakGroup label="Sidebar density" t={t}>
        <div style={{display:'flex', gap:6}}>
          {['roomy','compact'].map(d => (
            <div key={d} onClick={()=>set('density', d)} style={{
              flex:1, padding:'8px 10px', fontSize:11, fontWeight:700,
              textAlign:'center', borderRadius:7, cursor:'pointer',
              background: settings.density===d ? t.ink : t.surface,
              color: settings.density===d ? t.bg : t.ink2,
              textTransform:'capitalize', border:`1px solid ${t.border}`,
            }}>{d}</div>
          ))}
        </div>
      </TweakGroup>

      <TweakGroup label="Right panel" t={t}>
        <div style={{display:'flex', gap:6, flexWrap:'wrap'}}>
          {[{id:'now-playing',l:'Now Playing'},{id:'queue',l:'Queue'},{id:'lyrics',l:'Lyrics'},{id:'hidden',l:'Hidden'}].map(p => (
            <div key={p.id} onClick={()=>set('rightPanel', p.id)} style={{
              flex:'1 1 45%', padding:'7px 8px', fontSize:10, fontWeight:700,
              textAlign:'center', borderRadius:6, cursor:'pointer',
              background: settings.rightPanel===p.id ? t.ink : t.surface,
              color: settings.rightPanel===p.id ? t.bg : t.ink2,
              border:`1px solid ${t.border}`,
            }}>{p.l}</div>
          ))}
        </div>
      </TweakGroup>

      <TweakGroup label="Screen" t={t}>
        <div style={{display:'flex', gap:6, flexWrap:'wrap'}}>
          {['home','library','album','search'].map(s => (
            <div key={s} onClick={()=>set('screen', s)} style={{
              flex:'1 1 45%', padding:'7px 8px', fontSize:10, fontWeight:700,
              textAlign:'center', borderRadius:6, cursor:'pointer',
              background: settings.screen===s ? t.ink : t.surface,
              color: settings.screen===s ? t.bg : t.ink2,
              textTransform:'capitalize', border:`1px solid ${t.border}`,
            }}>{s}</div>
          ))}
        </div>
      </TweakGroup>
    </div>
  );
}

function TweakGroup({ label, t, children }) {
  return (
    <div style={{marginBottom:14}}>
      <div style={{fontSize:9, fontWeight:800, color:t.ink3, textTransform:'uppercase',
        letterSpacing:'0.1em', marginBottom:6}}>{label}</div>
      {children}
    </div>
  );
}

Object.assign(window, { RightPanel, NowPlayingPanel, QueuePanel, LyricsPanel, FullPlayer, TweaksPanel });
