// Jellify desktop — demo data

const ARTISTS = [
  { name:'Grateful Dead', genre:'Rock · Live', albums:38, tracks:1204 },
  { name:'Saloli', genre:'Electronic', albums:3, tracks:28 },
  { name:'Khruangbin', genre:'Psychedelic', albums:6, tracks:64 },
  { name:'Big Thief', genre:'Indie Folk', albums:5, tracks:58 },
  { name:'Sonny Rollins', genre:'Jazz', albums:22, tracks:188 },
  { name:'Alice Coltrane', genre:'Spiritual Jazz', albums:11, tracks:92 },
  { name:'Fleetwood Mac', genre:'Rock', albums:18, tracks:201 },
  { name:'Bob Dylan', genre:'Folk', albums:39, tracks:498 },
  { name:'Duke Ellington', genre:'Jazz', albums:55, tracks:712 },
  { name:'John Coltrane', genre:'Jazz', albums:48, tracks:604 },
];

const RECENT_ALBUMS = [
  { title:'The Deep End', artist:'Saloli', year:2020, tracks:10 },
  { title:'Cornell 5/8/77', artist:'Grateful Dead', year:1977, tracks:22 },
  { title:'Mordechai', artist:'Khruangbin', year:2020, tracks:10 },
  { title:'Blood on the Tracks', artist:'Bob Dylan', year:1975, tracks:10 },
  { title:'The Dance', artist:'Fleetwood Mac', year:1997, tracks:17 },
  { title:'Two Hands', artist:'Big Thief', year:2019, tracks:10 },
  { title:'Journey in Satchidananda', artist:'Alice Coltrane', year:1971, tracks:7 },
  { title:'Saxophone Colossus', artist:'Sonny Rollins', year:1956, tracks:5 },
];

const PLAYLISTS = [
  { title:'Live Recordings', count:412, seed:'live' },
  { title:'In Rotation', count:28, seed:'rot' },
  { title:'Sunday Morning', count:66, seed:'sun' },
  { title:'Drives with Dad', count:41, seed:'dad' },
  { title:'Not Work Music', count:193, seed:'notwork' },
  { title:'Late Night Jazz', count:88, seed:'lnj' },
  { title:'Cornell \'77 Forever', count:22, seed:'c77' },
];

const TRACKS = [
  { id:1, title:'Yona', artist:'Saloli', album:'The Deep End', duration:'3:42', year:2020, downloaded:true, fav:true, plays:142 },
  { id:2, title:'The Deep End', artist:'Saloli', album:'The Deep End', duration:'4:21', year:2020, downloaded:true, plays:98 },
  { id:3, title:'August Moon', artist:'Khruangbin', album:'Mordechai', duration:'5:03', year:2020, fav:true, plays:64 },
  { id:4, title:'Simple Twist of Fate', artist:'Bob Dylan', album:'Blood on the Tracks', duration:'6:54', year:1975, plays:31 },
  { id:5, title:'Fire on the Mountain', artist:'Grateful Dead', album:'Cornell 5/8/77', duration:'15:18', year:1977, downloaded:true, fav:true, plays:212 },
  { id:6, title:'Silver Springs', artist:'Fleetwood Mac', album:'The Dance', duration:'4:28', year:1997, fav:true, plays:44 },
  { id:7, title:'Not', artist:'Big Thief', album:'Two Hands', duration:'7:10', year:2019, plays:22 },
  { id:8, title:'In a Sentimental Mood', artist:'Duke Ellington & John Coltrane', album:'Duke Ellington & John Coltrane', duration:'4:15', year:1963, fav:true, plays:87 },
  { id:9, title:'Scarlet Begonias', artist:'Grateful Dead', album:'Cornell 5/8/77', duration:'8:42', year:1977, downloaded:true, plays:156 },
  { id:10, title:'Time Moves Slow', artist:'BADBADNOTGOOD', album:'IV', duration:'3:57', year:2016, plays:19 },
  { id:11, title:'Journey in Satchidananda', artist:'Alice Coltrane', album:'Journey in Satchidananda', duration:'6:33', year:1971, fav:true, plays:77 },
  { id:12, title:'St. Thomas', artist:'Sonny Rollins', album:'Saxophone Colossus', duration:'6:45', year:1956, plays:12 },
  { id:13, title:'Paper Crown', artist:'Alec Benjamin', album:'Narrated for You', duration:'2:39', year:2018, plays:8 },
  { id:14, title:'Masters of War', artist:'Bob Dylan', album:'The Freewheelin\' Bob Dylan', duration:'4:32', year:1963, plays:5 },
  { id:15, title:'Shipping Up to Boston', artist:'Dropkick Murphys', album:'The Warrior\'s Code', duration:'2:34', year:2005, plays:3 },
];

// Album detail tracks (for "The Deep End")
const ALBUM_TRACKS = [
  { n:1, title:'Too Much Silicon Too Little Sand', duration:'4:12', fav:false },
  { n:2, title:'The Deep End', duration:'4:21', fav:false, downloaded:true },
  { n:3, title:'Yona', duration:'3:42', fav:true, downloaded:true },
  { n:4, title:'Sand', duration:'3:18', fav:false },
  { n:5, title:'Paragons', duration:'5:02', fav:false },
  { n:6, title:'Something Small', duration:'2:44', fav:true },
  { n:7, title:'Kinder', duration:'4:03', fav:false },
  { n:8, title:'Underground Reservoir', duration:'6:17', fav:false, downloaded:true },
  { n:9, title:'Ferry', duration:'3:55', fav:false },
  { n:10, title:'Wade', duration:'4:49', fav:true },
];

const QUEUE_UP_NEXT = [
  { title:'The Deep End', artist:'Saloli', duration:'4:21' },
  { title:'Sand', artist:'Saloli', duration:'3:18' },
  { title:'Paragons', artist:'Saloli', duration:'5:02' },
  { title:'August Moon', artist:'Khruangbin', duration:'5:03' },
  { title:'Silver Springs', artist:'Fleetwood Mac', duration:'4:28' },
  { title:'Fire on the Mountain', artist:'Grateful Dead', duration:'15:18' },
];

Object.assign(window, { ARTISTS, RECENT_ALBUMS, PLAYLISTS, TRACKS, ALBUM_TRACKS, QUEUE_UP_NEXT });
