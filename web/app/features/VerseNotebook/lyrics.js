(() => {
  const {service, uuid} = window.Kaka;
  const styles = {
    story: {label: 'Storytelling'},
    freestyle: {label: 'Freestyle'},
    punch: {label: 'Punchlines'},
  };
  const cues = new Set(['breathe', 'tight', 'pick-up']);

  async function generate({topic, style, bpm, length, scheme, roomID}) {
    if (typeof topic !== 'string' || !topic.trim() || topic.length > 32 || !Object.prototype.hasOwnProperty.call(styles, style)
        || ![4, 8, 16].includes(length) || !['AABB', 'ABAB'].includes(scheme)
        || !Number.isInteger(bpm) || bpm < 60 || bpm > 180) {
      throw new Error('Check your topic, tempo and bar count.');
    }
    const value = await service.request('verse.generate', {topic, style, bpm, length, scheme, roomID});
    if (!Array.isArray(value?.bars) || value.bars.length !== length) {
      throw new Error('The service returned an incomplete verse. Try again.');
    }
    const bars = value.bars.map((bar, index) => {
      if (!bar || typeof bar.text !== 'string' || !bar.text.trim() || bar.text.length > 160
          || !['verse', 'hook'].includes(bar.section) || !cues.has(bar.cue)
          || typeof bar.rhyme !== 'string' || !/^[a-z]{1,4}$/i.test(bar.rhyme)) {
        throw new Error('The service returned a verse that could not be opened.');
      }
      return {index: index + 1, section: bar.section, text: bar.text.trim(), rhyme: bar.rhyme, cue: bar.cue};
    });
    const now = Date.now();
    return {id: uuid(), topic, style, bpm, scheme, roomID, bars, createdAt: now, updatedAt: now};
  }

  window.Kaka.lyrics = {provider: {generate}, styles};
})();
