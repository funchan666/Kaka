(() => {
  /** @typedef {{topic: string, style: string, bpm: number, length: number, scheme: string, roomID: string|null}} VerseRequest */
  /** @typedef {{index: number, section: string, text: string, rhyme: string, cue: string}} LyricBar */
  /** @typedef {{id: string, topic: string, style: string, bpm: number, scheme: string, roomID: string|null,
      bars: LyricBar[], createdAt: number, updatedAt: number}} VerseScore */
  const {uuid} = window.Kaka;
  const rhymeBanks = [
    {key: 'ight', tails: ['I bring it into light', 'let it carry through the night', 'the window’s burning bright',
      'I keep the corner in my sight', 'one breath and I’m all right', 'I hold the timing tight',
      'I put the doubt to flight', 'then let the last word bite']},
    {key: 'ow', tails: ['I let the moment go', 'there’s room to take it slow', 'feel the pavement catch the flow',
      'the block is washed in glow', 'I know what not to show', 'let the bassline run below',
      'give the next idea room to grow', 'tell me what the walls still know']},
    {key: 'ay', tails: ['I find a line to say', 'the busy street gives way', 'I’ll make it home by day',
      'I leave the beat to play', 'I shake the dust away', 'the rhythm makes me stay',
      'I take the long way', 'let the last word lay']},
    {key: 'een', tails: ['leave space between the scene', 'I keep the edges clean', 'I tell you where I’ve been',
      'behind the walls of green', 'I name the things unseen', 'then cut across the screen',
      'I show you what I mean', 'let the line sit in between']},
  ];

  const styles = {
    story: {
      label: 'Storytelling',
      lines: [
        'I put “[topic]” down in ink', 'The same old corner comes around', 'Steel rails sing beneath my feet', 'I save a word for morning',
        'I pull my collar past my chin', 'Your outline turns and leaves again', 'Half a ticket in my book', 'The crowd thins out and I look back',
        'I fold the hour into paper', 'Yesterday is on the stairs', 'The doors shut on my last line', 'The drums pick up the silence',
      ],
      hook: ['Same block under different lights', 'My footsteps take the lead', 'I sing “[topic]” one more time', 'I let the last note fall'],
    },
    freestyle: {
      label: 'Freestyle',
      lines: [
        'Throw me “[topic]” on the one', 'I start before the second guess', 'I catch the word you left behind', 'I put the hard part on the beat',
        'I try it back against the wall', 'You drop a word and I pick up', 'My two left feet find time', 'I leave a gap for what comes next',
        'We take the block another round', 'I knock the corners off the phrase', 'Halfway through I switch my step', 'I take the last round under breath',
      ],
      hook: ['Put the mic down for a beat', 'Step back in on the same one', 'Give me “[topic]” one more round', 'I leave the next beat to you'],
    },
    punch: {
      label: 'Punchlines',
      lines: [
        'I open with “[topic]”', 'I cross the extra words out', 'The low end drops a verdict', 'Two plain words can hold their ground',
        'A whisper can land on the one', 'One true word lifts the dust', 'The old tape knows my grip', 'I choose a rhyme and let one go',
        'Every pause is on the clock', 'I crush the line that won’t sit right', 'I turn the treble down for drums', 'Cut the line short enough for wax',
      ],
      hook: ['Soft voice with a heavy line', 'One word gives the drum a gap', 'Keep “[topic]” in the last four', 'I close it when the stage goes dim'],
    },
  };

  /** @param {VerseRequest} request @returns {VerseScore} */
  function generate({topic, style, bpm, length, scheme, roomID}) {
    if (!topic || topic.length > 32 || !styles[style] || ![4, 8, 16].includes(length)
      || !Number.isInteger(bpm) || bpm < 60 || bpm > 180 || !['AABB', 'ABAB'].includes(scheme)) {
      throw new Error('Check your topic, tempo and bar count.');
    }
    const pick = crypto.getRandomValues(new Uint32Array(2));
    const start = pick[0] % rhymeBanks.length;
    const banks = [rhymeBanks[start], rhymeBanks[(start + 1 + pick[1] % (rhymeBanks.length - 1)) % rhymeBanks.length]];
    const uses = [0, 0];
    const mode = styles[style];
    const bars = Array.from({length}, (_, index) => {
      const hook = length > 4 && index >= length - 4;
      const bankIndex = scheme === 'ABAB' ? index % 2 : Math.floor(index / 2) % 2;
      const bank = banks[bankIndex];
      const lead = hook ? mode.hook[index - (length - 4)] : mode.lines[index];
      const tail = bank.tails[(pick[1] + uses[bankIndex]) % bank.tails.length];
      uses[bankIndex] += 1;
      return {
        index: index + 1,
        section: hook ? 'hook' : 'verse',
        text: lead.replace('[topic]', () => topic) + ', ' + tail,
        rhyme: bank.key,
        cue: (index + 1) % 4 === 0 ? 'breathe' : (bpm >= 104 ? 'tight' : 'pick-up'),
      };
    });
    const now = Date.now();
    return {id: uuid(), topic, style, bpm, scheme, roomID, bars, createdAt: now, updatedAt: now};
  }

  // The composer consumes this contract independently of the generation provider.
  window.Kaka.lyrics = {provider: {generate: async (request) => generate(request)}, styles};
})();
