(() => {
  const {uuid} = window.Kaka;
  const storageKey = 'kaka.studio.v1';
  const native = window.webkit?.messageHandlers?.kakaStudio;
  let workspace;
  let revision = 0;
  let record;
  let writeQueue = Promise.resolve();

  function starter(session) {
    return {
      schema: 1,
      profile: {name: session.name ?? 'Guest artist', bio: '', style: ''},
      favorites: [],
      following: [],
      notes: [],
      scores: [],
      reports: [],
    };
  }

  function bounded(value, limit, min = 0) {
    return typeof value === 'string' && value.length <= limit && value.length >= min;
  }

  function validScore(score) {
    return score && bounded(score.id, 36, 36) && bounded(score.topic, 32, 1)
      && ['story', 'freestyle', 'punch'].includes(score.style)
      && Number.isInteger(score.bpm) && score.bpm >= 60 && score.bpm <= 180
      && ['AABB', 'ABAB'].includes(score.scheme)
      && (score.roomID === null || bounded(score.roomID, 64, 1))
      && Number.isFinite(score.createdAt) && Number.isFinite(score.updatedAt)
      && Array.isArray(score.bars) && [4, 8, 16].includes(score.bars.length)
      && score.bars.every((bar, index) => bar && bar.index === index + 1
        && bounded(bar.text, 160, 1) && bounded(bar.rhyme, 4, 1)
        && ['verse', 'hook'].includes(bar.section) && bounded(bar.cue, 24, 1));
  }

  function assertRecord(data) {
    const {schema, profile, favorites, following, notes, scores, reports} = data ?? {};
    if (schema !== 1 || !profile
      || !bounded(profile.name, 24, 1) || !bounded(profile.style, 20) || !bounded(profile.bio, 120)
      || !Array.isArray(favorites) || favorites.length > 64 || !favorites.every((id) => bounded(id, 64, 1))
      || !Array.isArray(following) || following.length > 64 || !following.every((id) => bounded(id, 64, 1))
      || !Array.isArray(notes) || notes.length > 64
      || !notes.every((note) => note && bounded(note.roomID, 64, 1) && bounded(note.text, 480, 1))
      || !Array.isArray(scores) || scores.length > 40 || !scores.every(validScore)
      || !Array.isArray(reports) || reports.length > 64
      || !reports.every((report) => report && bounded(report.roomID, 64, 1)
        && bounded(report.reason, 24, 1) && Number.isFinite(report.createdAt))) {
      throw new Error('Kaka could not read your saved work.');
    }
  }

  async function call(command, fields = {}) {
    if (!native) return browserCommand(command, fields);
    const id = uuid();
    let timer;
    try {
      const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('bridge-timeout')), 6000);
      });
      const response = await Promise.race([native.postMessage({version: 1, id, command, ...fields}), timeout]);
      if (response?.id !== id) throw new Error('bridge-response');
      return response.value;
    } finally {
      clearTimeout(timer);
    }
  }

  function browserCommand(command, fields) {
    if (command === 'ready') return null;
    const guest = {token: 'browser-guest', name: null, email: null};
    if (command === 'auth.session') return sessionStorage.getItem('kaka.guest') ? guest : null;
    if (command === 'auth.guest') {
      sessionStorage.setItem('kaka.guest', '1');
      return guest;
    }
    if (command === 'auth.signOut' && fields.session === guest.token) {
      sessionStorage.removeItem('kaka.guest');
      return null;
    }
    if (command.startsWith('auth.')) throw new Error('auth-needs-app');
    if (fields.session !== guest.token || !sessionStorage.getItem('kaka.guest')) throw new Error('session-changed');
    const snapshot = JSON.parse(localStorage.getItem(storageKey) || 'null') ?? {revision: 0, recordJSON: null};
    if (command === 'records.read') return snapshot;
    if (command !== 'records.write' || snapshot.revision !== fields.revision) throw new Error('write-conflict');
    const updated = {revision: snapshot.revision + 1, recordJSON: fields.recordJSON};
    localStorage.setItem(storageKey, JSON.stringify(updated));
    return updated;
  }

  function apply(snapshot, session = workspace) {
    if (!Number.isSafeInteger(snapshot?.revision) || snapshot.revision < 0
      || (snapshot.revision !== 0 && typeof snapshot.recordJSON !== 'string')) {
      throw new Error('Kaka could not read this version of your saved work.');
    }
    const next = snapshot.revision === 0 ? starter(session) : JSON.parse(snapshot.recordJSON);
    if (next?.schema === 1 && !Object.prototype.hasOwnProperty.call(next, 'following')) next.following = [];
    if (next?.profile?.name === '\u672a\u8bbe\u7f6e\u827a\u540d' && !next.profile.bio && !next.profile.style) {
      next.profile.name = session.name ?? 'Guest artist';
    }
    // Previously saved scores retain their lyrics while their section and cue labels are localized.
    for (const score of Array.isArray(next?.scores) ? next.scores : []) {
      for (const bar of Array.isArray(score?.bars) ? score.bars : []) {
        if (!bar) continue;
        if (bar.section === '\u4e3b\u6b4c') bar.section = 'verse';
        if (bar.section === '\u526f\u6b4c') bar.section = 'hook';
        if (bar.cue === '\u5c3e\u62cd\u6362\u6c14') bar.cue = 'breathe';
        if (bar.cue === '\u5207\u77ed\u8bcd\u7ec4') bar.cue = 'tight';
        if (bar.cue === '\u7b2c\u4e00\u62cd\u8fdb') bar.cue = 'pick-up';
      }
    }
    assertRecord(next);
    revision = snapshot.revision;
    record = next;
  }

  async function open(session) {
    apply(await call('records.read', {session: session.token}), session);
    workspace = session;
  }

  function close() {
    workspace = undefined;
    record = undefined;
    revision = 0;
  }

  function update(mutate) {
    const session = workspace?.token;
    const transaction = writeQueue.then(async () => {
      if (!session || session !== workspace?.token) throw new Error('Your session changed. Please sign in again.');
      const draft = JSON.parse(JSON.stringify(record));
      mutate(draft);
      assertRecord(draft);
      const serialized = JSON.stringify(draft);
      try {
        apply(await call('records.write', {session, revision, recordJSON: serialized}));
      } catch {
        // A write can finish before its reply arrives. Check the committed snapshot before retrying.
        let latest;
        try {
          latest = await call('records.read', {session});
          apply(latest);
        } catch {
          throw new Error('Your changes could not be saved. Please try again.');
        }
        if (latest.recordJSON !== serialized) {
          window.dispatchEvent(new Event('kaka:records'));
          throw new Error('Your changes could not be saved. Please try again.');
        }
      }
      window.dispatchEvent(new Event('kaka:records'));
    });
    writeQueue = transaction.catch(() => {});
    return transaction;
  }

  window.Kaka.records = {
    open,
    close,
    current: () => record,
    call,
    ready: () => call('ready'),
    settled: () => writeQueue,
    update,
    isHidden: (roomID) => record.reports.some((report) => report.roomID === roomID),
  };
})();
