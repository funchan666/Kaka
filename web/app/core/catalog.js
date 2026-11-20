(() => {
  const Kaka = window.Kaka;
  const genres = [['all', 'All rooms'], ['open-mic', 'Open mic'], ['cypher', 'Freestyle'], ['beats', 'Beat lab']];
  const reportReasons = [
    ['HARASS', 'Harassment or bullying'],
    ['NUDITY', 'Nudity or sexual content'],
    ['SPAM', 'Spam or scam'],
    ['UNDERAGE', 'Underage user'],
    ['FRAUD', 'Fraud'],
    ['OTHER', 'Other'],
  ];
  const pageSize = 10;
  const directory = {
    live: {rooms: [], loading: false, error: '', page: 0, more: false},
    voice: {rooms: [], loading: false, error: '', page: 0, more: false},
  };
  const people = new Map();
  const following = new Set();
  let session;
  let revision = 0;
  let followingError = '';
  let followingConfirmed = false;
  let followingLoad;

  function emit() {
    window.dispatchEvent(new Event('kaka:catalog'));
  }

  function first(object, ...fields) {
    for (const name of fields) {
      const value = object?.[name];
      if (typeof value === 'string' && value.trim()) return value.trim();
      if (typeof value === 'number' && Number.isFinite(value)) return String(value);
    }
    return '';
  }

  function identifier(object, ...fields) {
    for (const field of fields) {
      const value = Number(first(object, field));
      if (Number.isSafeInteger(value) && value > 0) return value;
    }
    return undefined;
  }

  function rows(value, fields) {
    if (Array.isArray(value)) return value;
    if (!value || typeof value !== 'object') return [];
    for (const name of fields) {
      const child = value[name];
      if (Array.isArray(child) || (child && typeof child === 'object')) return rows(child, fields);
    }
    return [];
  }

  function mediaURL(value) {
    if (!value) return '';
    try {
      const address = new URL(value);
      return address.protocol === 'https:' && !address.username && !address.password ? address.href : '';
    } catch {
      return '';
    }
  }

  function image(file, className, fallback = 'stage.jpg') {
    const node = Kaka.image(fallback, className);
    const address = mediaURL(file);
    if (address) {
      node.referrerPolicy = 'no-referrer';
      node.addEventListener('error', () => { node.src = 'assets/images/' + fallback; }, {once: true});
      node.src = address;
    }
    return node;
  }

  function person(raw, fallback, party = false) {
    const value = raw?.venueBrief ?? raw?.astralPortrait ?? raw?.detail ?? raw?.profile ?? raw?.user ?? raw;
    const remoteID = party ? identifier(value, 'userId', 'id') : identifier(value, 'voyagerBadge', 'orbitMark');
    if (fallback && remoteID && fallback !== remoteID) return undefined;
    const serverID = remoteID ?? fallback;
    if (!serverID) return undefined;
    const id = String(serverID);
    const previous = people.get(id);
    return {
      id, serverID,
      name: first(value, 'nickname', 'castMoniker', 'nickName', 'hostName', 'ownerName') || previous?.name || 'Host',
      portrait: mediaURL(first(value, 'cometGlyph', 'spotlightFace', 'icon', 'avatar')) || previous?.portrait || '',
      style: first(value, 'rapStyle', 'style') || previous?.style || '',
      bio: first(value, 'cipherSeal', 'showSummary', 'signature', 'description') || previous?.bio || '',
    };
  }

  function registerPerson(person) {
    if (!person) return '';
    people.set(person.id, person);
    return person.id;
  }

  function parseRoom(value, kind) {
    const voice = kind === 'voice';
    const serverID = voice ? identifier(value, 'id', 'roomId') : identifier(value, 'habitatTag', 'orbitMark');
    if (!serverID || (voice && Number(value.roomStatus) === 2)) return undefined;
    const id = voice ? 'party-' + serverID : String(serverID);
    const hostData = voice ? {...value, ...value.owner, ...value.anchor, id: undefined} : value.anchor ?? value.anchorInfo ?? value;
    const owner = person(hostData, voice ? identifier(value, 'ownerId') : identifier(value, 'voyagerBadge'), voice);
    const host = registerPerson(owner);
    const title = (voice ? first(value, 'roomName') : first(value, 'programTitle', 'roomName')) || owner?.name || 'Room ' + serverID;
    const cover = mediaURL(voice ? first(value, 'roomAvatar', 'bigImgUrl') : first(value, 'stageBackdrop', 'roomCover')) || owner?.portrait || '';
    const bpm = Number(first(value, 'bpm'));
    const genre = first(value, 'genre');
    const viewers = first(value, 'fanGather', 'onlineNum', 'onlineCount', 'memberCount');
    return {
      kind, id, serverID, title, cover, host,
      format: first(value, 'format') || (voice ? 'Voice room' : 'Live'),
      genre: genres.some(([key]) => key === genre) ? genre : '',
      bpm: Number.isInteger(bpm) && bpm >= 60 && bpm <= 180 ? bpm : null,
      viewers: /^\d+$/.test(viewers) ? Number(viewers) : null,
      topic: first(value, 'topic') || title,
      description: first(value, 'description', 'showSummary', 'roomSubtitle', 'greetingMessage', 'announcement'),
      exercise: first(value, 'exercise'),
      style: first(value, 'style') || 'freestyle',
      locked: voice && ['lockFlag', 'needPassword', 'isLock', 'locked'].some((key) => [1, true, '1', 'true'].includes(value[key])),
      channel: first(value, 'studioRoute', 'venueKey', 'agoraChannelId'),
    };
  }

  function clear() {
    revision += 1;
    session = undefined;
    people.clear();
    following.clear();
    followingLoad = undefined;
    followingError = '';
    followingConfirmed = false;
    for (const state of Object.values(directory)) {
      Object.assign(state, {rooms: [], loading: false, error: '', page: 0, more: false});
    }
  }

  async function refreshRooms(kind, append = false) {
    const state = directory[kind];
    if (!session || state.loading || (append && !state.more)) return;
    const stamp = revision;
    const live = kind === 'live';
    const page = append ? state.page + 1 : 1;
    state.loading = true;
    state.error = '';
    emit();
    try {
      const value = await Kaka.service.request(
        live ? 'listLiveRooms' : 'listVoiceRooms',
        live ? {stagePage: page, folioScale: pageSize, desertSector: false} : {pageSize: 20, languageCode: '', version: 'v2'},
        session.token,
      );
      if (revision !== stamp) return;
      const values = rows(value, live
        ? ['gridBands', 'records', 'roster', 'data', 'result', 'nebulaPieces']
        : ['rows', 'records', 'list', 'data', 'result', 'items']);
      const next = new Map((append ? state.rooms : []).map((room) => [room.id, room]));
      for (const item of values) {
        const room = parseRoom(item, kind);
        if (room) next.set(room.id, room);
      }
      const added = !append || next.size > state.rooms.length;
      state.rooms = [...next.values()];
      state.page = page;
      const count = Number(first(value, 'cosmicSum'));
      state.more = live && added && (count >= next.size && count > 0 ? count > next.size : values.length >= pageSize);
    } catch (error) {
      if (revision === stamp) state.error = error?.message || 'Rooms could not load.';
    } finally {
      if (revision === stamp) {
        state.loading = false;
        emit();
      }
    }
  }

  function refreshFollowing() {
    if (!session) return Promise.resolve();
    if (followingLoad) return followingLoad;
    const stamp = revision;
    followingError = '';
    const task = (async () => {
      try {
        const value = await Kaka.service.request('listFollowing', {signalKind: 3}, session.token);
        if (revision !== stamp) return;
        for (const item of rows(value, ['gridBands', 'records', 'roster', 'data', 'result', 'nebulaPieces'])) {
          const id = registerPerson(person(item));
          if (id) following.add(id);
        }
        followingConfirmed = true;
      } catch (error) {
        if (revision === stamp) followingError = error?.message || 'Following could not load.';
      } finally {
        if (revision === stamp) {
          followingLoad = undefined;
          emit();
        }
      }
    })();
    followingLoad = task;
    return task;
  }

  async function load(nextSession) {
    clear();
    session = nextSession;
    await Promise.all([refreshRooms('live'), refreshRooms('voice'), refreshFollowing()]);
  }

  async function refreshHost(host) {
    const stamp = revision;
    const value = await Kaka.service.request('getHost', {voyagerBadge: host.serverID}, session?.token);
    if (revision !== stamp) return undefined;
    const fresh = person(value, host.serverID);
    if (!fresh) throw new Error('This host could not be verified.');
    registerPerson(fresh);
    return fresh;
  }

  async function toggleFollow(host) {
    if (!session) throw new Error('Sign in to follow a host.');
    if (!followingConfirmed) await refreshFollowing();
    if (!followingConfirmed) throw new Error(followingError || 'Following could not load.');
    const stamp = revision;
    const add = !following.has(host.id);
    await Kaka.service.request('setRelationship', {fanHandle: host.serverID, supportMode: add ? 1 : 2}, session?.token);
    if (revision !== stamp) return undefined;
    if (add) following.add(host.id);
    else following.delete(host.id);
    emit();
    return add;
  }

  async function refreshLive(room) {
    const stamp = revision;
    const value = await Kaka.service.request('getLiveRoom', {habitatTag: room.serverID}, session?.token);
    if (revision !== stamp) return undefined;
    const raw = identifier(value, 'habitatTag', 'orbitMark') === room.serverID ? value : value?.venueBrief;
    const id = identifier(raw, 'habitatTag', 'orbitMark');
    if (id !== room.serverID) throw new Error('This stream is no longer available.');
    const updated = parseRoom(raw, 'live');
    if ((room.host && updated.host && room.host !== updated.host) || (room.channel && updated.channel && room.channel !== updated.channel)) {
      throw new Error('This stream has changed. Return to Live Rooms to reload it.');
    }
    return {...room, ...updated};
  }

  Kaka.catalog = {
    load, clear, refreshRooms, refreshHost, refreshLive, refreshFollowing, toggleFollow, image, mediaURL,
    rooms: (kind) => kind ? directory[kind].rooms.slice() : [...directory.live.rooms, ...directory.voice.rooms],
    room: (id) => (id?.startsWith('party-') ? directory.voice : directory.live).rooms.find((room) => room.id === id),
    status: (kind) => ({loading: directory[kind].loading, error: directory[kind].error, more: directory[kind].more}),
    hosts: () => [...people.values()],
    host: (id) => people.get(id),
    follows: (id) => following.has(id),
    following: () => [...following].map((id) => people.get(id)).filter(Boolean),
    followingError: () => followingError,
    genres,
    reportReasons,
  };
})();
