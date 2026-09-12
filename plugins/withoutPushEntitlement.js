// expo-notifications unconditionally adds the aps-environment (push) entitlement
// for remote notifications. Morsel only schedules local notifications and has no
// backend to send remote push from, and a free Apple "Personal Team" cannot sign
// an app that requests this entitlement at all. Strip it back out.
const { withEntitlementsPlist } = require('expo/config-plugins');

module.exports = function withoutPushEntitlement(config) {
  return withEntitlementsPlist(config, (config) => {
    delete config.modResults['aps-environment'];
    return config;
  });
};
