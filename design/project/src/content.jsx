// Jellify desktop — reusable content pieces (rows, cards, sections)

function SectionHeader({ title, subtitle, t, trailing, size = 'md' }) {
  return (
    <div style={{
      display:'flex', alignItems:'flex-end', justifyContent:'space-between',
      padding: size === 'lg' ? '24px 0 14px' : '18px 0 10px', gap:16,
    }}>
      <div>
        <div style={{fontSize: size === 'lg' ? 24 : 18, fontWeight:800, color:t.ink,
          letterSpacing:'-0.02em', lineHeight:1.1, fontFamily:FONT_FAMILY}}>{title}</div>
        {subtitle && <div style={{fontSize:12, color:t.ink2, fontWeight:500, marginTop:3}}>{subtitle}</div>}
      </div>
      {trailing}
    </div>
  );
}

function ViewAll({ t, onClick, label = 'See all' }) {
  return (
    <div onClick={onClick} style={{
      fontSize:11, fontWeight:700, color:t.ink2, cursor:'pointer',
      textTransform:'uppercase', letterSpacing:'0.08em',
      display:'flex', alignItems:'center', gap:4,
    }}>
      {label} <Icon name="chevron-right" size={12}/>
    </div>
  );
}

// Grid of album/artwork cards
function AlbumGrid({ items, t, onItem, circle, cols = 6, playing }) {
  return (
    <div style={{display:'grid', gridTemplateColumns:`repeat(${cols}, 1fr)`, gap:18}}>
      {items.map((it, i) => (
        <AlbumCard key={i} item={it} t={t} onClick={()=>onItem && onItem(it)}
          circle={circle} playing={playing && (playing.album === it.title || playing.artist === it.name)}/>
      ))}
    </div>
  );
}

function AlbumCard({ item, t, onClick, circle, playing }) {
  const [hover, setHover] = React.useState(false);
  const seed = item.title || item.name || 'x';
  return (
    <div onClick={onClick}
      onMouseEnter={()=>setHover(true)} onMouseLeave={()=>setHover(false)}
      style={{
        cursor:'pointer', padding:10, borderRadius:12,
        background: hover ? t.surface : 'transparent',
        transition:'background 0.15s',
      }}>
      <div style={{position:'relative'}}>
        <Artwork seed={seed} size="100%" radius={circle ? 999 : 8}
          style={{width:'100%', aspectRatio:'1 / 1', height:'auto'}}/>
        {/* Floating play button */}
        <div style={{
          position:'absolute', right:8, bottom:8,
          width:40, height:40, borderRadius:'50%',
          background: playing ? t.accent : t.primary,
          display:'flex', alignItems:'center', justifyContent:'center',
          boxShadow:`0 8px 20px ${playing ? 'rgba(204,47,113,0.45)' : 'rgba(136,123,255,0.45)'}`,
          opacity: hover || playing ? 1 : 0,
          transform: `translateY(${hover||playing ? 0 : 8}px)`,
          transition:'all 0.2s cubic-bezier(0.22,1,0.36,1)',
        }}>
          <Icon name={playing ? 'pause' : 'play'} size={16} color="#fff" fill/>
        </div>
      </div>
      <div style={{marginTop:10}}>
        <div style={{fontSize:13, fontWeight:700, color: playing ? t.accent : t.ink,
          whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis', letterSpacing:'-0.01em'}}>
          {item.title || item.name}
        </div>
        <div style={{fontSize:11, color:t.ink2, fontWeight:500, marginTop:2,
          whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>
          {item.artist || item.genre || (item.count ? `${item.count} tracks` : '')}
          {item.year ? <span style={{color:t.ink3}}> · {item.year}</span> : null}
        </div>
      </div>
    </div>
  );
}

// Horizontal carousel
function Carousel({ title, items, t, circle, onItem, playing }) {
  return (
    <div>
      <SectionHeader title={title} t={t} trailing={<ViewAll t={t}/>}/>
      <div style={{display:'grid', gridTemplateColumns:'repeat(auto-fill, minmax(170px, 1fr))', gap:12}}>
        {items.slice(0, 8).map((it, i) => (
          <AlbumCard key={i} item={it} t={t} onClick={()=>onItem && onItem(it)}
            circle={circle}
            playing={playing && (playing.album === it.title || playing.artist === it.name)}/>
        ))}
      </div>
    </div>
  );
}

// Track list header (desktop style — # · Title · Album · Duration · actions)
function TrackListHeader({ t, showAlbum = true, showPlays = false }) {
  return (
    <div style={{
      display:'grid',
      gridTemplateColumns: `32px 1fr ${showAlbum ? '1.2fr ' : ''}${showPlays ? '80px ' : ''}60px 40px`,
      padding:'6px 16px 8px', gap:12,
      fontSize:10, fontWeight:700, color:t.ink3,
      textTransform:'uppercase', letterSpacing:'0.08em',
      borderBottom:`1px solid ${t.border}`,
    }}>
      <div style={{textAlign:'center'}}>#</div>
      <div>Title</div>
      {showAlbum && <div>Album</div>}
      {showPlays && <div style={{textAlign:'right'}}>Plays</div>}
      <div style={{textAlign:'right'}}><Icon name="clock" size={12}/></div>
      <div/>
    </div>
  );
}

function TrackRow({ t, track, n, showAlbum = true, showPlays = false, active, playing, onPlay }) {
  const [hover, setHover] = React.useState(false);
  const [fav, setFav] = React.useState(track.fav);
  return (
    <div onClick={()=>onPlay && onPlay(track)}
      onDoubleClick={()=>onPlay && onPlay(track)}
      onMouseEnter={()=>setHover(true)} onMouseLeave={()=>setHover(false)}
      style={{
        display:'grid',
        gridTemplateColumns: `32px 1fr ${showAlbum ? '1.2fr ' : ''}${showPlays ? '80px ' : ''}60px 40px`,
        alignItems:'center', gap:12,
        padding:'8px 16px', cursor:'pointer',
        background: hover ? t.rowHover : (active ? t.surface2 : 'transparent'),
        borderRadius:6,
      }}>
      <div style={{textAlign:'center', fontSize:12, fontWeight:500,
        color: active ? t.accent : t.ink3, fontVariantNumeric:'tabular-nums'}}>
        {active && playing ? <Equalizer color={t.accent}/> : (hover ? <Icon name="play" size={12} color={t.ink} fill/> : n)}
      </div>
      <div style={{display:'flex', alignItems:'center', gap:12, minWidth:0}}>
        <Artwork seed={track.title} size={34} radius={4} style={{boxShadow:'none'}}/>
        <div style={{minWidth:0}}>
          <div style={{fontSize:13, fontWeight:600,
            color: active ? t.accent : t.ink,
            whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>{track.title}</div>
          <div style={{fontSize:11, color:t.ink2, fontWeight:500,
            whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>{track.artist}</div>
        </div>
      </div>
      {showAlbum && (
        <div style={{fontSize:12, color:t.ink2, fontWeight:500,
          whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>{track.album}</div>
      )}
      {showPlays && (
        <div style={{fontSize:11, color:t.ink3, fontWeight:600, textAlign:'right', fontVariantNumeric:'tabular-nums'}}>
          {(track.plays||0).toLocaleString()}
        </div>
      )}
      <div style={{display:'flex', alignItems:'center', justifyContent:'flex-end', gap:8, minWidth:0}}>
        {track.downloaded && <Icon name="check-circle" size={14} color={t.teal}/>}
        <div onClick={e => { e.stopPropagation(); setFav(!fav); }}
          style={{opacity: fav || hover ? 1 : 0, transition:'opacity 0.1s', cursor:'pointer'}}>
          <Icon name="heart" size={14} color={fav ? t.accent : t.ink2} fill={fav}/>
        </div>
        <div style={{fontSize:12, color:t.ink2, fontWeight:500, fontVariantNumeric:'tabular-nums', minWidth:36, textAlign:'right'}}>
          {track.duration}
        </div>
      </div>
      <div onClick={e=>e.stopPropagation()} style={{opacity: hover ? 1 : 0, transition:'opacity 0.1s'}}>
        <Icon name="dots" size={14} color={t.ink2}/>
      </div>
    </div>
  );
}

function Equalizer({ color = '#fff' }) {
  return (
    <div style={{display:'inline-flex', alignItems:'flex-end', gap:2, height:14, justifyContent:'center'}}>
      {[0,1,2].map(i => (
        <div key={i} style={{
          width:3, borderRadius:1, background:color,
          animation:`eq${i} ${0.6 + i*0.12}s ease-in-out ${i*0.08}s infinite alternate`,
          height: 6 + i*3,
        }}/>
      ))}
      <style>{`
        @keyframes eq0 { from { height: 2px } to { height: 12px } }
        @keyframes eq1 { from { height: 10px } to { height: 4px } }
        @keyframes eq2 { from { height: 4px } to { height: 14px } }
      `}</style>
    </div>
  );
}

// A "tile" link – a clickable big button for quick library shortcuts
function QuickTile({ item, t, onClick }) {
  const [hover, setHover] = React.useState(false);
  return (
    <div onClick={onClick}
      onMouseEnter={()=>setHover(true)} onMouseLeave={()=>setHover(false)}
      style={{
        display:'flex', alignItems:'center', gap:12,
        padding:10, paddingRight:14, borderRadius:8,
        background: hover ? t.surface2 : t.surface,
        cursor:'pointer', position:'relative', overflow:'hidden',
      }}>
      <Artwork seed={item.seed || item.title} size={48} radius={4} style={{boxShadow:'none'}}/>
      <div style={{flex:1, minWidth:0, fontSize:13, fontWeight:700, color:t.ink,
        whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>{item.title}</div>
      <div style={{
        width:36, height:36, borderRadius:'50%',
        background: t.primary, display:'flex', alignItems:'center', justifyContent:'center',
        opacity: hover ? 1 : 0, transform: `translateX(${hover ? 0 : 8}px)`, transition:'all 0.2s',
        boxShadow:`0 6px 14px rgba(136,123,255,0.4)`, flexShrink:0,
      }}>
        <Icon name="play" size={14} color="#fff" fill/>
      </div>
    </div>
  );
}

function Chip({ label, active, onClick, t }) {
  return (
    <div onClick={onClick} style={{
      padding:'7px 14px', borderRadius:999, fontSize:12, fontWeight:600,
      background: active ? t.ink : t.surface2,
      color: active ? t.bg : t.ink,
      cursor:'pointer', whiteSpace:'nowrap',
      border:`1px solid ${active ? t.ink : t.border}`,
      transition:'all 0.12s',
    }}>{label}</div>
  );
}

Object.assign(window, { SectionHeader, ViewAll, AlbumGrid, AlbumCard, Carousel, TrackListHeader, TrackRow, Equalizer, QuickTile, Chip });
