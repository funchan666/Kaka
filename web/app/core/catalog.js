(() => {
  /** @typedef {{id: string, title: string, format: string, genre: string, bpm: number, topic: string,
      style: string, host: string, description: string, exercise: string, cover?: string}} StageSession */
  /** @typedef {{id: string, name: string, style: string, portrait: string, bio: string}} ProgramHost */
  /** @type {ProgramHost[]} */
  const hosts = [
    {id: 'lan', name: 'Lan', style: 'Storytelling', portrait: 'host-lan.jpg',
      bio: 'Lan starts with the sounds on her block. At her open mic, everyone gets four bars and a chance to finish the story before feedback.'},
    {id: 'du', name: 'Du', style: 'Freestyle', portrait: 'host-du.jpg',
      bio: 'Du leaves the next emcee a word to pick up. He likes passing the mic before anyone knows where the verse is going.'},
    {id: 'mikee', name: 'Mikee', style: 'Boom bap', portrait: 'host-mikee.jpg',
      bio: 'Mikee works in the gaps between the drums. Try the same line at two tempos and listen for where it lands.'},
  ];
  /** @type {StageSession[]} */
  const rooms = [
    {
      id: 'basement-mic', title: 'Basement Mic', format: 'Open mic', genre: 'open-mic', bpm: 92,
      topic: 'After the last train', style: 'story', host: 'lan', cover: 'cypher-cover.jpg',
      description: 'Tell a city story in four bars. Pick a corner, a sound and someone passing by. Open with a scene people can picture.',
      exercise: 'Set the scene in bar one and bring in a sound in bar two. End bars three and four on the same rhyme.',
    },
    {
      id: 'back-to-back', title: 'Back-to-Back', format: 'Freestyle relay', genre: 'cypher', bpm: 106,
      topic: 'Freestyle on the corner', style: 'freestyle', host: 'du',
      description: 'Pass the mic every four bars. Use the last word you heard to start your next line and keep the rhythm going.',
      exercise: 'Start with “crossroads” and finish your fourth bar with “echo.” Use “echo” to open the next round.',
    },
    {
      id: 'breakbeat-room', title: 'Breakbeat Lab', format: 'Beat breakdown', genre: 'beats', bpm: 84,
      topic: 'A new side to an old record', style: 'punch', host: 'mikee',
      description: 'Set a line against a slow boom bap beat. Put your strongest word on the downbeat and leave a gap for the drums.',
      exercise: 'Stress your main word on beat one. Fill beats two and three, then leave beat four open.',
    },
    {
      id: 'hook-after-dark', title: 'Hooks After Dark', format: 'Open mic', genre: 'open-mic', bpm: 78,
      topic: 'A letter to my midnight self', style: 'story', host: 'lan',
      description: 'Start with a short line you could say twice. Give the hook two endings the room can remember.',
      exercise: 'Say a bar twice with the same stresses. Shorten the line in bars three and four to find the hook.',
    },
  ];

  const byID = new Map(rooms.map((room) => [room.id, room]));
  const hostByID = new Map(hosts.map((host) => [host.id, host]));
  const genres = [['all', 'All rooms'], ['open-mic', 'Open mic'], ['cypher', 'Freestyle'], ['beats', 'Beat lab']];
  const reportReasons = ['Inappropriate content', 'Spam or advertising', 'Privacy concern', 'Other'];

  window.Kaka.catalog = {
    rooms: () => rooms.slice(),
    room: (id) => byID.get(id),
    host: (id) => hostByID.get(id),
    genres,
    reportReasons,
  };
})();
