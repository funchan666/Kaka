(() => {
  const {records} = window.Kaka;
  const messages = {
    'service-unconfigured': 'The service connection has not been configured.',
    'service-network': 'Couldn’t reach the service. Check your connection and try again.',
    'service-unavailable': 'This service isn’t available right now.',
    'service-session-expired': 'Your session ended. Please log in again.',
    'session-changed': 'Your session ended. Please log in again.',
    'auth-input': 'Check your details and try again.',
    'media-unavailable': 'Room audio and video aren’t available in this build.',
    'media-invalid-room': 'This room is no longer available.',
    'media-busy': 'Another room connection is in progress.',
    'media-timeout': 'The room took too long to respond. Try joining again.',
    'media-connection': 'Couldn’t connect to the room. Try joining again.',
    'media-cancelled': 'The room connection ended.',
    'media-permission': 'Allow microphone access in Settings to speak in a voice room.',
    'media-seat': 'That seat is no longer available. Try another seat.',
    'media-heartbeat': 'Your microphone connection ended. Join the seat again to speak.',
    'avatar-busy': 'A profile photo is already being updated.',
    'avatar-presentation': 'Couldn’t open your photos. Try again.',
    'avatar-image': 'That photo couldn’t be opened. Choose another photo.',
    'avatar-upload': 'Couldn’t upload the photo. Check your connection and try again.',
    'avatar-response': 'The profile service couldn’t save that photo.',
    'gift-unavailable': 'Gifts aren’t available in this live room.',
    'gift-refresh': 'The gift or its price changed. Refresh the list to review it again.',
    'gift-busy': 'Another gift request is in progress.',
    'gift-balance': 'Your balance is too low for this gift.',
  };
  let session;
  let mediaRevision = 0;
  let joining;
  let mediaReleased = Promise.resolve();

  function errorCode(error) {
    const value = error?.message ?? String(error);
    return Object.keys(messages).find((code) => value.includes(code));
  }

  function errorMessage(error) {
    return messages[errorCode(error)] ?? 'The service couldn’t complete the request. Try again.';
  }

  async function send(operation, input, token) {
    if (!token || token !== session) throw new Error(messages['session-changed']);
    try {
      const value = await records.call('service.request', {operation, input, session: token});
      if (token !== session) throw new Error('session-changed');
      return value;
    } catch (error) {
      const code = errorCode(error);
      if (token === session && ['session-changed', 'service-session-expired'].includes(code)) {
        session = undefined;
        window.dispatchEvent(new Event('kaka:session-expired'));
      }
      throw new Error(errorMessage(error));
    }
  }

  async function joinMedia(input, token) {
    const revision = mediaRevision;
    await mediaReleased;
    if (revision !== mediaRevision) throw new Error(messages['media-cancelled']);
    if (joining) throw new Error(messages['media-busy']);
    const attempt = send('joinRoomMedia', input, token);
    joining = attempt;
    try {
      return await attempt;
    } finally {
      joining = undefined;
    }
  }

  function request(operation, input = {}, token = session) {
    if (operation === 'joinRoomMedia') return joinMedia(input, token);
    if (operation === 'leaveRoomMedia') {
      mediaRevision += 1;
      // The native leave cancels an in-flight join. A new room waits for both to settle.
      const release = send(operation, input, token);
      mediaReleased = Promise.allSettled([mediaReleased, joining, release]).then(() => undefined);
      return release;
    }
    return send(operation, input, token);
  }

  window.Kaka.service = {request, errorMessage, setSession: (next) => { session = next?.token; }};
})();
