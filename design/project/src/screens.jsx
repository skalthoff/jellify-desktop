// Jellify desktop — screens

// ─── Home ──────────────────────────────────────────────────────────────
function HomeScreen({ t, onPlay, current }) {
  const quick = [
    { title:'Live Recordings', seed:'live' },
    { title:'Cornell 5/8/77', seed:'Cornell 5/8/77' },
    { title:'The Deep End', seed:'The Deep End' },
    { title:'In Rotation', seed:'rot' },
    { title:'Mordechai', seed:'Mordechai' },
    { title:'Drives with Dad', seed:'dad' },
  ];
  const now = new Date();
  const hour = now.getHours();
  const greet = hour < 5 ? 'still up?' : hour < 12 ? 'good morning, soren' : hour < 18 ? 'good afternoon' : 'good evening';
  return (
    <div style={{padding:'24px 32px 48px', fontFamily:FONT_FAMILY}}>
      <div style={{
        display:'flex', alignItems:'flex-end', justifyContent:'space-between',
        marginBottom:20,
      }}>
        <div>
          <div style={{fontSize:12, fontWeight:700, color:t.ink2, textTransform:'uppercase',
            letterSpacing:'0.1em', marginBottom:6}}>In Rotation</div>
          <h1 style={{fontSize:42, fontWeight:900, color:t.ink, letterSpacing:'-0.03em',
            lineHeight:1, margin:0, fontStyle:'italic'}}>{greet}</h1>
          <div style={{fontSize:14, color:t.ink2, fontWeight:500, marginTop:10, maxWidth:560}}>
            4,208 tracks synced from <span style={{color:t.ink, fontWeight:700}}>jellyfin.home.arpa</span>.
            Pick up where you left off, or let <em style={{color:t.accent, fontStyle:'italic'}}>instant mix</em> find you something new.
          </div>
        </div>
        <div style={{display:'flex', gap:8}}>
          <BigBtn icon="mix" label="Instant Mix" t={t} primary/>
          <BigBtn icon="shuffle" label="Shuffle All" t={t}/>
        </div>
      </div>

      {/* Quick tiles grid */}
      <div style={{display:'grid', gridTemplateColumns:'repeat(3, 1fr)', gap:10, marginTop:8, marginBottom:8}}>
        {quick.map((q, i) => <QuickTile key={i} item={q} t={t} onClick={()=>onPlay({title:q.title, artist:'—', album:q.title, duration:'3:42'})}/>)}
      </div>

      <Carousel title="Recently Played" items={RECENT_ALBUMS} t={t}
        onItem={(a)=>onPlay({title:a.title, artist:a.artist, album:a.title, duration:'4:21'})}
        playing={current}/>

      <SectionHeader title="Artists You Love" t={t} trailing={<ViewAll t={t}/>}/>
      <div style={{display:'grid', gridTemplateColumns:'repeat(auto-fill, minmax(150px, 1fr))', gap:12, marginBottom:12}}>
        {ARTISTS.slice(0,6).map((a, i) => <AlbumCard key={i} item={a} t={t} circle/>)}
      </div>

      <Carousel title="Jump Back In" items={RECENT_ALBUMS.slice().reverse()} t={t}
        onItem={(a)=>onPlay({title:a.title, artist:a.artist, album:a.title, duration:'4:21'})}/>

      <Carousel title="Your Playlists" items={PLAYLISTS} t={t}/>
    </div>
  );
}

function BigBtn({ icon, label, t, primary, onClick }) {
  return (
    <button onClick={onClick} style={{
      display:'inline-flex', alignItems:'center', gap:8,
      padding:'10px 18px', borderRadius:999, cursor:'pointer',
      fontFamily:FONT_FAMILY, fontSize:13, fontWeight:700,
      background: primary ? t.ink : 'transparent',
      color: primary ? t.bg : t.ink,
      border: `1px solid ${primary ? t.ink : t.borderStrong}`,
      letterSpacing:'-0.01em',
    }}>
      <Icon name={icon} size={14}/>
      {label}
    </button>
  );
}

// ─── Library ───────────────────────────────────────────────────────────
function LibraryScreen({ t, onPlay, current, playing }) {
  const [tab, setTab] = React.useState('Tracks');
  const [view, setView] = React.useState('list');
  const tabs = ['Tracks','Albums','Artists','Playlists','Downloaded'];
  return (
    <div style={{padding:'24px 32px 48px', fontFamily:FONT_FAMILY}}>
      <div style={{display:'flex', alignItems:'center', justifyContent:'space-between', marginBottom:18}}>
        <div>
          <div style={{fontSize:12, fontWeight:700, color:t.ink2, textTransform:'uppercase', letterSpacing:'0.1em', marginBottom:4}}>Your Library</div>
          <h1 style={{fontSize:36, fontWeight:900, color:t.ink, letterSpacing:'-0.03em', margin:0}}>Library</h1>
        </div>
        <div style={{display:'flex', gap:6, alignItems:'center', background:t.surface,
          padding:3, borderRadius:8, border:`1px solid ${t.border}`}}>
          <ViewToggle icon="list" active={view==='list'} t={t} onClick={()=>setView('list')}/>
          <ViewToggle icon="grid" active={view==='grid'} t={t} onClick={()=>setView('grid')}/>
        </div>
      </div>

      <div style={{display:'flex', gap:8, marginBottom:18, flexWrap:'wrap'}}>
        {tabs.map(x => <Chip key={x} label={x} active={tab===x} onClick={()=>setTab(x)} t={t}/>)}
      </div>

      <div style={{display:'flex', alignItems:'center', justifyContent:'space-between', marginBottom:8}}>
        <div style={{fontSize:11, fontWeight:700, color:t.ink3, textTransform:'uppercase', letterSpacing:'0.08em'}}>
          {tab === 'Tracks' ? `${TRACKS.length} tracks · Sorted by A–Z` :
           tab === 'Albums' ? `${RECENT_ALBUMS.length} albums` :
           tab === 'Artists' ? `${ARTISTS.length} artists` :
           tab === 'Playlists' ? `${PLAYLISTS.length} playlists` :
           '148 tracks available offline'}
        </div>
        <div style={{display:'flex', gap:6}}>
          <IconBtn icon="filter" t={t} size={14}/>
          <IconBtn icon="sort" t={t} size={14}/>
        </div>
      </div>

      {tab === 'Tracks' && view === 'list' && (
        <div>
          <TrackListHeader t={t} showPlays/>
          {TRACKS.map((tr, i) => (
            <TrackRow key={tr.id} track={tr} n={i+1} t={t} showPlays
              active={current && current.title === tr.title}
              playing={playing}
              onPlay={onPlay}/>
          ))}
        </div>
      )}
      {tab === 'Albums' && (
        <AlbumGrid items={RECENT_ALBUMS} t={t} cols={5}
          onItem={(a)=>onPlay({title:a.title, artist:a.artist, album:a.title, duration:'4:21'})}
          playing={current}/>
      )}
      {tab === 'Artists' && (
        <AlbumGrid items={ARTISTS} t={t} cols={6} circle/>
      )}
      {tab === 'Playlists' && (
        <AlbumGrid items={PLAYLISTS} t={t} cols={5}/>
      )}
      {tab === 'Downloaded' && (
        <div>
          <TrackListHeader t={t}/>
          {TRACKS.filter(x=>x.downloaded).map((tr, i) => (
            <TrackRow key={tr.id} track={tr} n={i+1} t={t}
              active={current && current.title === tr.title}
              playing={playing} onPlay={onPlay}/>
          ))}
        </div>
      )}
      {tab === 'Tracks' && view === 'grid' && (
        <AlbumGrid items={TRACKS.map(x => ({...x, name: x.title}))} t={t} cols={5}
          onItem={(x)=>onPlay(x)} playing={current}/>
      )}
    </div>
  );
}

function ViewToggle({ icon, active, t, onClick }) {
  return (
    <div onClick={onClick} style={{
      width:28, height:24, borderRadius:5,
      display:'flex', alignItems:'center', justifyContent:'center', cursor:'pointer',
      background: active ? t.ink : 'transparent',
      color: active ? t.bg : t.ink2,
    }}>
      <Icon name={icon} size={13}/>
    </div>
  );
}

// ─── Album Detail ──────────────────────────────────────────────────────
function AlbumScreen({ t, onPlay, current, playing }) {
  const album = { title:'The Deep End', artist:'Saloli', year:2020, label:'Kranky', tracks:10, duration:'42 min' };
  const totalSec = ALBUM_TRACKS.reduce((s, x) => s + durationSec(x.duration), 0);
  return (
    <div style={{fontFamily:FONT_FAMILY}}>
      {/* Hero — editorial layout: large artwork left, type-forward info right.
          No gradient wash. A single hairline and generous negative space do the work. */}
      <div style={{
        padding:'44px 40px 28px',
        display:'grid', gridTemplateColumns:'240px 1fr', gap:36,
        alignItems:'end',
        borderBottom:`1px solid ${t.border}`,
        position:'relative',
      }}>
        {/* ambient dots pattern in the corner — small signature detail */}
        <div aria-hidden style={{
          position:'absolute', right:24, top:24, width:120, height:60,
          backgroundImage:`radial-gradient(${t.ink3} 1px, transparent 1px)`,
          backgroundSize:'8px 8px', opacity:0.35, pointerEvents:'none',
        }}/>

        <div style={{position:'relative'}}>
          <Artwork seed={album.title} size={240} radius={6}/>
        </div>

        <div style={{minWidth:0, paddingBottom:4}}>
          <div style={{fontSize:11, fontWeight:700, color:t.accent,
            textTransform:'uppercase', letterSpacing:'0.14em'}}>
            Long-Player · {album.year}
          </div>

          <h1 style={{
            fontSize:72, fontWeight:900, color:t.ink,
            letterSpacing:'-0.04em', margin:'10px 0 6px', lineHeight:0.9,
            fontStyle:'italic',
          }}>{album.title}</h1>

          <div style={{fontSize:20, color:t.ink, fontWeight:600, letterSpacing:'-0.01em', marginBottom:18}}>
            by <span style={{
              borderBottom:`2px solid ${t.accent}`, paddingBottom:1,
            }}>{album.artist}</span>
          </div>

          {/* Stats bar — monospaced numbers, labels underneath. Feels like a liner-note sleeve. */}
          <div style={{display:'flex', gap:28, marginTop:6}}>
            <Stat t={t} value={album.tracks} label="Tracks"/>
            <Stat t={t} value={album.duration.replace(' min','')} label="Minutes"/>
            <Stat t={t} value={album.label} label="Label"/>
            <Stat t={t} value="FLAC" label="Format"/>
          </div>
        </div>
      </div>

      <div style={{padding:'20px 32px 8px', display:'flex', alignItems:'center', gap:14}}>
        <div onClick={()=>onPlay({title:ALBUM_TRACKS[0].title, artist:album.artist, album:album.title, duration:ALBUM_TRACKS[0].duration})}
          style={{
            width:54, height:54, borderRadius:'50%', background:t.accent,
            display:'flex', alignItems:'center', justifyContent:'center', cursor:'pointer',
            boxShadow:`0 10px 24px ${t.accent}55`,
          }}>
          <Icon name="play" size={22} color="#fff" fill/>
        </div>
        <IconBtn icon="shuffle" t={t} size={20}/>
        <IconBtn icon="heart" t={t} size={20} active/>
        <IconBtn icon="download" t={t} size={20}/>
        <IconBtn icon="plus" t={t} size={20}/>
        <IconBtn icon="dots-v" t={t} size={20}/>
      </div>

      <div style={{padding:'12px 32px 48px'}}>
        <TrackListHeader t={t} showAlbum={false}/>
        {ALBUM_TRACKS.map((tr, i) => (
          <TrackRow key={i}
            track={{...tr, artist:album.artist, album:album.title}}
            n={tr.n} t={t} showAlbum={false}
            active={current && current.title === tr.title} playing={playing}
            onPlay={()=>onPlay({title:tr.title, artist:album.artist, album:album.title, duration:tr.duration, fav:tr.fav})}/>
        ))}
        <div style={{padding:'16px 4px 0', fontSize:11, color:t.ink3, fontWeight:500}}>
          Released {album.year} · {album.label} · {formatTime(totalSec)} runtime
        </div>
      </div>
    </div>
  );
}

// ─── Search ─────────────────────────────────────────────────────────────
function SearchScreen({ t, onPlay, current, playing, query, setQuery }) {
  const q = (query||'').toLowerCase();
  const results = q ? TRACKS.filter(x => x.title.toLowerCase().includes(q) || x.artist.toLowerCase().includes(q) || x.album.toLowerCase().includes(q)) : [];
  const matchArtists = q ? ARTISTS.filter(a => a.name.toLowerCase().includes(q)) : [];
  const matchAlbums = q ? RECENT_ALBUMS.filter(a => a.title.toLowerCase().includes(q) || a.artist.toLowerCase().includes(q)) : [];
  return (
    <div style={{padding:'24px 32px 48px', fontFamily:FONT_FAMILY}}>
      <div style={{marginBottom:20}}>
        <div style={{fontSize:12, fontWeight:700, color:t.ink2, textTransform:'uppercase', letterSpacing:'0.1em', marginBottom:6}}>Search</div>
        <div style={{
          display:'flex', alignItems:'center', gap:12,
          background:t.surface, border:`1px solid ${t.borderStrong}`,
          borderRadius:14, padding:'14px 18px',
        }}>
          <Icon name="search" size={20} color={t.ink2}/>
          <input value={query||''} onChange={e=>setQuery(e.target.value)}
            autoFocus
            placeholder="Artists, albums, tracks — what are we listening to?"
            style={{flex:1, background:'transparent', border:'none', outline:'none',
              color:t.ink, fontFamily:FONT_FAMILY, fontSize:18, fontWeight:500,
              letterSpacing:'-0.01em'}}/>
          {q && <div onClick={()=>setQuery('')} style={{cursor:'pointer'}}>
            <Icon name="close" size={16} color={t.ink2}/>
          </div>}
        </div>
      </div>

      {!q && (
        <div>
          <SectionHeader title="Recent Searches" t={t}/>
          <div style={{display:'flex', flexDirection:'column', gap:2}}>
            {['saloli', 'grateful dead', 'live recordings', 'khruangbin', 'alice coltrane'].map(s => (
              <div key={s} onClick={()=>setQuery(s)} style={{
                display:'flex', alignItems:'center', gap:12, padding:'10px 12px',
                borderRadius:8, cursor:'pointer',
              }}
                onMouseEnter={e=>e.currentTarget.style.background=t.surface}
                onMouseLeave={e=>e.currentTarget.style.background='transparent'}>
                <Icon name="history" size={14} color={t.ink3}/>
                <div style={{flex:1, fontSize:13, color:t.ink, fontWeight:500}}>{s}</div>
                <Icon name="close" size={12} color={t.ink3}/>
              </div>
            ))}
          </div>
          <SectionHeader title="Browse Genres" t={t}/>
          <div style={{display:'grid', gridTemplateColumns:'repeat(4, 1fr)', gap:12}}>
            {['Jazz','Rock','Live','Electronic','Folk','Psychedelic','Spiritual','Indie'].map((g, i) => (
              <GenreTile key={g} label={g} seed={g} t={t}/>
            ))}
          </div>
        </div>
      )}

      {q && results.length === 0 && matchArtists.length === 0 && (
        <div style={{textAlign:'center', padding:'60px 0', color:t.ink2}}>
          <div style={{fontSize:18, fontWeight:700, color:t.ink, marginBottom:4}}>No results for "{query}"</div>
          <div style={{fontSize:13}}>Try a different spelling, or search your Jellyfin library directly.</div>
        </div>
      )}

      {q && (matchArtists.length > 0 || matchAlbums.length > 0) && (
        <div>
          {matchArtists[0] && (
            <div>
              <SectionHeader title="Top Result" t={t}/>
              <div style={{
                display:'flex', alignItems:'center', gap:18,
                background:t.surface, borderRadius:12, padding:18, marginBottom:20,
                border:`1px solid ${t.border}`,
              }}>
                <Artwork seed={matchArtists[0].name} size={100} radius={999}/>
                <div style={{flex:1}}>
                  <div style={{fontSize:11, fontWeight:700, color:t.ink3, textTransform:'uppercase', letterSpacing:'0.08em'}}>Artist</div>
                  <div style={{fontSize:28, fontWeight:800, color:t.ink, letterSpacing:'-0.02em', margin:'4px 0'}}>{matchArtists[0].name}</div>
                  <div style={{fontSize:12, color:t.ink2, fontWeight:500}}>{matchArtists[0].genre} · {matchArtists[0].albums} albums · {matchArtists[0].tracks} tracks</div>
                </div>
                <div style={{
                  width:52, height:52, borderRadius:'50%', background:t.accent,
                  display:'flex', alignItems:'center', justifyContent:'center', cursor:'pointer',
                  boxShadow:`0 8px 20px ${t.accent}55`,
                }}>
                  <Icon name="play" size={20} color="#fff" fill/>
                </div>
              </div>
            </div>
          )}
          {matchAlbums.length > 0 && (
            <div>
              <SectionHeader title="Albums" t={t}/>
              <AlbumGrid items={matchAlbums} t={t} cols={5}
                onItem={(a)=>onPlay({title:a.title, artist:a.artist, album:a.title, duration:'4:21'})}/>
            </div>
          )}
          {results.length > 0 && (
            <div style={{marginTop:20}}>
              <SectionHeader title="Tracks" t={t}/>
              <TrackListHeader t={t}/>
              {results.map((tr, i) => (
                <TrackRow key={tr.id} track={tr} n={i+1} t={t}
                  active={current && current.title === tr.title} playing={playing} onPlay={onPlay}/>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function Stat({ t, value, label }) {
  return (
    <div>
      <div style={{fontSize:22, fontWeight:800, color:t.ink, letterSpacing:'-0.02em',
        fontVariantNumeric:'tabular-nums', lineHeight:1}}>{value}</div>
      <div style={{fontSize:10, fontWeight:700, color:t.ink3, textTransform:'uppercase',
        letterSpacing:'0.1em', marginTop:4}}>{label}</div>
    </div>
  );
}

function GenreTile({ label, seed, t }) {
  const palettes = [['#4B0FD6','#FF066F'],['#0F3D48','#57E9C9'],['#271055','#A96BFF'],
    ['#541A2E','#FF6625'],['#10314F','#2FA6D9'],['#3A1655','#CC2F71'],['#1B0A4C','#57E9C9'],['#5B153B','#FFD166']];
  let h = 0; for (let i=0;i<seed.length;i++) h = (h*31 + seed.charCodeAt(i)) >>> 0;
  const [a, b] = palettes[h % palettes.length];
  return (
    <div style={{
      position:'relative', height:88, borderRadius:10, overflow:'hidden',
      background:`linear-gradient(135deg, ${a}, ${b})`,
      padding:16, cursor:'pointer',
    }}>
      <div style={{fontSize:18, fontWeight:800, color:'#fff', letterSpacing:'-0.02em', position:'relative', zIndex:2}}>{label}</div>
      <div style={{position:'absolute', right:-8, bottom:-10, width:54, height:54,
        borderRadius:6, background:'rgba(255,255,255,0.15)', transform:'rotate(20deg)'}}/>
    </div>
  );
}

Object.assign(window, { HomeScreen, LibraryScreen, AlbumScreen, SearchScreen, BigBtn, ViewToggle, GenreTile, Stat });
