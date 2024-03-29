jQuery(document).ready(function($) {

    // save previously focused item when we open
    $(document).on('open.fndtn.reveal', '[data-reveal]', function () {
      var $modal = $(this);
      $modal.data( "previously_focused", $( ":focus" ) );
    });

    // focus on the first input, for keyboard users
    $(document).on('opened.fndtn.reveal', '[data-reveal]', function () {
      var $modal = $(this);

      $modal.data( "previously_focused", $( ":focus" ) );
      $modal.find( "input:visible:first" ).focus();
    });

    // switch back focus
    $(document).on('closed.fndtn.reveal', '[data-reveal]', function () {
        var $modal = $(this);

        var focused = $modal.data( "previously_focused" );
        $(focused).focus();
    } );

});