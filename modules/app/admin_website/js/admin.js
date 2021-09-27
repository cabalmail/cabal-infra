/*global CabalAdmin _config*/

var CabalAdmin = window.CabalAdmin || {};
CabalAdmin.address = CabalAdmin.address || {};

(function addressScopeWrapper($) {
    var authToken;
    CabalAdmin.authToken.then(function setAuthToken(token) {
        if (token) {
            authToken = token;
        } else {
            window.location.href = 'index.html';
        }
    }).catch(function handleTokenError(error) {
        displayUpdate(error);
        window.location.href = 'index.html';
    });
    function requestAddress(obj) {
        $.ajax({
            method: 'POST',
            url: _config.api.invokeUrl + '/new',
            headers: {
                Authorization: authToken
            },
            data: JSON.stringify(obj),
            contentType: 'application/json',
            success: completeRequestAddress,
            error: ajaxError
        });
    }

    function ajaxError(jqXHR, textStatus, errorThrown) {
        console.error('Error requesting address: ', textStatus, ', Details: ', errorThrown);
        console.error('Response: ', jqXHR.responseText);
        displayUpdate('An error occurred when requesting your address.');
    }

    function completeRequestAddress(result) {
        address = result.address;
        listAddresses();
        displayUpdate('Your address ' + address + ' has been requested, and copied to your clipboard. Please allow 5 minutes for your address to become active.');
    }

    function listAddresses() {
        $.ajax({
            method: 'GET',
            url: _config.api.invokeUrl + '/list',
            headers: {
                Authorization: authToken
            },
            success: completeRequestList,
            error: function ajaxError(jqXHR, textStatus, errorThrown) {
                console.log('Error listing addresses: ', textStatus, ', Details: ', errorThrown);
                console.log('Response: ', jqXHR);
                console.log('Trying again...')
                // one more try
                setTimeout(function () {
                    $.ajax({
                        method: 'GET',
                        url: _config.api.invokeUrl + '/list',
                        headers: {
                            Authorization: authToken
                        },
                        success: completeRequestList,
                        error: function ajaxError(jqXHR, textStatus, errorThrown) {
                            console.error('Error listing addresses: ', textStatus, ', Details: ', errorThrown);
                            console.error('Response: ', jqXHR);
                            displayUpdate('An error occurred when listing addresses. Try reloading this page.');
                            $('#address-list').html('<p>No results. Reload to try again.</p>');
                        }
                    })
                },1000);
            }
        });
    }

    function completeRequestList(result) {
      CabalAdmin.items = result.Items;
      CabalAdmin.items.sort((a,b) => { return a.tld+a.subdomain > b.tld+b.subdomain ? 1 : -1 });
      displayList();
    }

    function displayList() {
      $('#address-list').empty();
      for (var i = 0; i < CabalAdmin.items.length; i++) {
        switch (CabalAdmin.user) {
          case 'leader@admin.cabalmail.com':
            break;
          case 'jake.carr@mail.randomsound.org':
            if (CabalAdmin.items[i].user != 'jake') {
              continue;
            }
            break;
          case 'depreisthecrist@gmail.com':
            if (CabalAdmin.items[i].user != 'tristan') {
              continue;
            }
            break;
          case 'cathy_carr@info.ccarr.com':
            if (CabalAdmin.items[i].user != 'cathy') {
              continue;
            }
            break;
          default:
        }
        if ($('#user-filter').val() != 'all') {
          if (CabalAdmin.items[i].user != $('#user-filter').val()) {
            continue;
          }
        }
        if ($('#zone_id-filter').val() != 'all') {
          if (CabalAdmin.items[i]['zone-id'] != $('#zone_id-filter').val()) {
            continue;
          }
        }
        if ($('#text').val() != '') {
          if (
            (CabalAdmin.items[i].address + CabalAdmin.items[i].comment)
            .toLowerCase().indexOf($('#text').val().toLowerCase()) == -1
          ) {
            continue;
          }
        }
        $('#address-list').append('<div class="item"><span class="view" id="view-' +
                                    i + '" data="' + i +
                                    '"><a href="#" title="Comment: ' +
                                    CabalAdmin.items[i].comment + '">' +
                                    CabalAdmin.items[i].address +
                                    '</a></span><span class="more" id="more-' +
                                    i + '" data="' + i +
                                    '"><a href="#" class="mobile">&gt;</a><a href="#" class="full">Details</a></span></div>');
        $('#more-' + i + ' .full').click(e => {
          $('#address-view').fadeIn(300);
        });
        $('#more-' + i + ' .mobile').click(e => {
          $('#address-view').show("slide",{direction:"right"},300);
        });
        $('#more-' + i).click(e => {
          var index = e.currentTarget.attributes.data.value;
          var item = CabalAdmin.items[index];
          $('#view-address').text(item.address);
          $('#view-comment').text(item.comment ? item.comment : '<No Comment>');
          $('#view-user').text(item.user);
          $('#view-username').text(item.username);
          $('#view-subdomain').text(item.subdomain);
          $('#view-tld').text(item.tld);
          $('#view-zone-id').text(item['zone-id']);
          // $('#address-view').css('display', 'block');
          $('#copy-address').text("Copy " + item.address);
          $('#copy-address').off().on('click', null, item.address, handleCopy);
          $('#view-revoke').off().on('click', null, item, e => {
            var item = e.data;
            var obj = {
              address: item.address,
              zone_id: item['zone-id'],
              subdomain: item.subdomain,
            };
            $.ajax({
                method: 'DELETE',
                url: _config.api.invokeUrl + '/revoke',
                headers: {
                    Authorization: authToken
                },
                data: JSON.stringify(obj),
                contentType: 'application/json',
                success: function() {
                  $('#address-view').fadeOut(300);
                  displayUpdate('Address "' + item.address + '" revoked');
                  listAddresses();
                },
                error: function ajaxError(jqXHR, textStatus, errorThrown) {
                    console.error('Error revoking address: ', textStatus, ', Details: ', errorThrown);
                    console.error('Response: ', jqXHR.responseText);
                    displayUpdate('An error occurred when revoking your address.');
                }
            });
          });
        });
        $('#view-' + i).click(CabalAdmin.items[i].address, handleCopy);
      }
    }

    function adjustFilters() {
      switch (CabalAdmin.user) {
        case 'leader@admin.cabalmail.com':
          $('#user-filter').val('chris');
          break;
        case 'cathy_carr@info.ccarr.com':
          $('#zone_id-filter').val('ZBYS915K03BC2');
          $("#zone_id-filter option[value='Z1FO2MQJDQEPLA']").remove();
          $("#zone_id-filter option[value='Z2UFK0POOZL6IV']").remove();
          $("#zone_id-filter option[value='Z1YIW2SGWFY5A7']").remove();
          $("#zone_id-filter option[value='Z1H7RU5O7WHDJH']").remove();
          $("#zone_id-filter option[value='Z1U9GPZMPLPCS7']").remove();
          $("#zone_id-filter option[value='Z33IB65UD0QYKU']").remove();
          $("#zone_id-filter option[value='Z2GS79AAMTQXNV']").remove();
          $("#zone_id-filter").css('display', 'none');
          $('#user-filter').val('cathy');
          $("#user-filter option[value='chris']").remove();
          $("#user-filter option[value='jake']").remove();
          $("#user-filter option[value='tristan']").remove();
          $("#user-filter").css('display', 'none');
          break;
        case 'jake.carr@mail.randomsound.org':
          $('#zone_id-filter').val('Z2GS79AAMTQXNV');
          $("#zone_id-filter option[value='ZBYS915K03BC2']").remove();
          $("#zone_id-filter option[value='Z2UFK0POOZL6IV']").remove();
          $("#zone_id-filter option[value='Z1YIW2SGWFY5A7']").remove();
          $("#zone_id-filter option[value='Z1H7RU5O7WHDJH']").remove();
          $("#zone_id-filter option[value='Z1U9GPZMPLPCS7']").remove();
          $('#user-filter').val('jake');
          $("#user-filter option[value='chris']").remove();
          $("#user-filter option[value='cathy']").remove();
          $("#user-filter option[value='tristan']").remove();
          $("#user-filter").css('display', 'none');
          break;
        case 'depreisthecrist@gmail.com':
          $('#zone_id-filter').val('Z1U9GPZMPLPCS7');
          $("#zone_id-filter option[value='Z1FO2MQJDQEPLA']").remove();
          $("#zone_id-filter option[value='ZBYS915K03BC2']").remove();
          $("#zone_id-filter option[value='Z2UFK0POOZL6IV']").remove();
          $("#zone_id-filter option[value='Z1YIW2SGWFY5A7']").remove();
          $("#zone_id-filter option[value='Z1H7RU5O7WHDJH']").remove();
          $("#zone_id-filter option[value='Z33IB65UD0QYKU']").remove();
          $("#zone_id-filter option[value='Z2GS79AAMTQXNV']").remove();
          $("#zone_id-filter").css('display', 'none');
          $('#user-filter').val('tristan');
          $("#user-filter option[value='chris']").remove();
          $("#user-filter option[value='cathy']").remove();
          $("#user-filter option[value='jake']").remove();
          $("#user-filter").css('display', 'none');
          break;
        default:
          $("#zone_id-filter option[value='Z1FO2MQJDQEPLA']").remove();
          $("#zone_id-filter option[value='ZBYS915K03BC2']").remove();
          $("#zone_id-filter option[value='Z2UFK0POOZL6IV']").remove();
          $("#zone_id-filter option[value='Z1YIW2SGWFY5A7']").remove();
          $("#zone_id-filter option[value='Z1H7RU5O7WHDJH']").remove();
          $("#zone_id-filter option[value='Z33IB65UD0QYKU']").remove();
          $("#zone_id-filter option[value='Z2GS79AAMTQXNV']").remove();
          $("#zone_id-filter option[value='Z1U9GPZMPLPCS7']").remove();
          $("#zone_id-filter").css('display', 'none');
          $("#user-filter option[value='chris']").remove();
          $("#user-filter option[value='cathy']").remove();
          $("#user-filter option[value='jake']").remove();
          $("#user-filter option[value='tristan']").remove();
          $("#user-filter").css('display', 'none');
      }
    }

    // Register click handler for #request button
    $(function onDocReady() {
        CabalAdmin.user = localStorage.getItem('CognitoIdentityServiceProvider.' + window._config.cognito.userPoolClientId + '.LastAuthUser');
        adjustFilters();
        $("#user-filter").change(displayList);
        $('#view-back').click(e => {
          $('#address-view').hide("slide",{direction:"right"},300);
        });
        $("#zone_id-filter").change(displayList);
        $("#text").keyup(displayList);
        listAddresses();
        $('#reload').click(listAddresses);
        $('#view-close').click(function() {
          $('#address-view').fadeOut(300);
        });

        $('#request').click(handleRequestClick);
        $('#random').click(handleRandomClick);
        $('#clear').click(handleClearClick);
        $('#cabalusername').focus();
        $('.tab-signOut').click(function() {
          CabalAdmin.signOut();
          window.location = "index.html";
        });
        $('.tab-new').on('click tap', function() {
          $('body').attr('class', 'new');
        });
        $('.tab-list').on('click tap', function() {
          $('body').attr('class', 'list');
        });

        switch (CabalAdmin.user) {
          case 'leader@admin.cabalmail.com':
            $('#zone_id').val('Z2UFK0POOZL6IV');
            $('#user').val('chris');
            break;
          case 'cathy_carr@info.ccarr.com':
            $('#zone_id').val('ZBYS915K03BC2');
            $("#zone_id option[value='Z1FO2MQJDQEPLA']").remove();
            $("#zone_id option[value='Z2UFK0POOZL6IV']").remove();
            $("#zone_id option[value='Z1YIW2SGWFY5A7']").remove();
            $("#zone_id option[value='Z1H7RU5O7WHDJH']").remove();
            $("#zone_id option[value='Z1U9GPZMPLPCS7']").remove();
            $("#zone_id option[value='Z33IB65UD0QYKU']").remove();
            $("#zone_id option[value='Z2GS79AAMTQXNV']").remove();
            $('#user').val('cathy');
            $("#user option[value='chris']").remove();
            $("#user option[value='jake']").remove();
            $("#user option[value='tristan']").remove();
            break;
          case 'jake.carr@mail.randomsound.org':
            $('#zone_id').val('Z2GS79AAMTQXNV');
            $("#zone_id option[value='ZBYS915K03BC2']").remove();
            $("#zone_id option[value='Z2UFK0POOZL6IV']").remove();
            $("#zone_id option[value='Z1YIW2SGWFY5A7']").remove();
            $("#zone_id option[value='Z1H7RU5O7WHDJH']").remove();
            $("#zone_id option[value='Z1U9GPZMPLPCS7']").remove();
            $('#user').val('jake');
            $("#user option[value='chris']").remove();
            $("#user option[value='cathy']").remove();
            $("#user option[value='tristan']").remove();
            break;
          case 'depreisthecrist@gmail.com':
            $('#zone_id').val('Z1U9GPZMPLPCS7');
            $("#zone_id option[value='Z1FO2MQJDQEPLA']").remove();
            $("#zone_id option[value='ZBYS915K03BC2']").remove();
            $("#zone_id option[value='Z2UFK0POOZL6IV']").remove();
            $("#zone_id option[value='Z1YIW2SGWFY5A7']").remove();
            $("#zone_id option[value='Z1H7RU5O7WHDJH']").remove();
            $("#zone_id option[value='Z33IB65UD0QYKU']").remove();
            $("#zone_id option[value='Z2GS79AAMTQXNV']").remove();
            $('#user').val('tristan');
            $("#user option[value='chris']").remove();
            $("#user option[value='cathy']").remove();
            $("#user option[value='jake']").remove();
            break;
          default:
            $("#zone_id option[value='Z1FO2MQJDQEPLA']").remove();
            $("#zone_id option[value='ZBYS915K03BC2']").remove();
            $("#zone_id option[value='Z2UFK0POOZL6IV']").remove();
            $("#zone_id option[value='Z1YIW2SGWFY5A7']").remove();
            $("#zone_id option[value='Z1H7RU5O7WHDJH']").remove();
            $("#zone_id option[value='Z33IB65UD0QYKU']").remove();
            $("#zone_id option[value='Z2GS79AAMTQXNV']").remove();
            $("#zone_id option[value='Z1U9GPZMPLPCS7']").remove();
            $("#user option[value='chris']").remove();
            $("#user option[value='cathy']").remove();
            $("#user option[value='jake']").remove();
            $("#user option[value='tristan']").remove();
        }

    });

    function handleRequestClick(event) {
        var obj = {
          address: $('#cabalusername').val() + '@' + $('#subdomain').val() + '.' + $('#zone_id option:selected').text(),
          zone_id: $('#zone_id option:selected').val(),
          cabalusername: $('#cabalusername').val(),
          subdomain: $('#subdomain').val(),
          user: $('#user option:selected').val(),
          comment: $('#comment').val()
        };
        var copytarget = document.getElementById('copytext');
        copytarget.value = obj.address;
        copytarget.focus();
        copytarget.setSelectionRange(0, copytarget.value.length);
        document.execCommand("copy");
        copytarget.blur();
        event.preventDefault();
        requestAddress(obj);
    }

    function handleCopy(event) {
      var copytarget = document.getElementById('copytext');
      copytarget.value = event.data;
      copytarget.focus();
      copytarget.setSelectionRange(0, copytarget.value.length);
      document.execCommand("copy");
      copytarget.blur();
      event.preventDefault();
      displayUpdate("Address " + event.data + " copied to clipboard.")
    }

    function displayUpdate(text) {
      $("div.success").text(text);
      $("div.success").fadeIn( 300 ).delay( 15000 ).fadeOut( 400 );
    }

    function uuidv4() {
      return ([1e7]+-1e3+-4e3+-8e3+-1e11).replace(/[018]/g, c =>
        (c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> c / 4).toString(16)
      )
    }
    
    function handleRandomClick(event) {
      var uuid = uuidv4().split('-');
      $('#cabalusername').val(uuid[0]+'-'+uuid[1]+'-'+uuid[2])
      $('#subdomain').val(uuid[3]+'-'+uuid[4])
    }

    function handleClearClick(event) {
      $('#cabalusername').val('')
      $('#subdomain').val('')
    }

}(jQuery));
