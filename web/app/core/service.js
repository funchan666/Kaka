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

  function errorCode(error) {
    const value = error?.message ?? String(error);
    return Object.keys(messages).find((code) => value.includes(code));
  }

  function errorMessage(error) {
    return messages[errorCode(error)] ?? 'The service couldn’t complete the request. Try again.';
  }

  async function request(operation, input = {}, token = session) {
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

  window.Kaka.service = {request, errorMessage, setSession: (next) => { session = next?.token; }};
})();
