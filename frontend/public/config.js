// Where the backend API lives. This is the only file to edit when deploying
// the frontend somewhere else.
window.APP_CONFIG = {
  // Full backend URL, e.g. 'https://api.example.com'. When set, the ports
  // below are ignored.
  apiBase: '',

  // Used when apiBase is empty: the backend is assumed to be on the same
  // host as this page (localhost or a LAN IP), on these ports.
  // TEMPORARY: 4100/4543 while the old chatapp still occupies 4000/4443.
  // Switch back to 4000/4443 once the old app is stopped.
  apiHttpPort: 4100,
  apiHttpsPort: 4543,
};
