#!/usr/bin/perl
#
# DW::Task::SphinxCopier
#
# Worker to copy content to our search system.
#
# Authors:
#     Mark Smith <mark@dreamwidth.org>
#
# Copyright (c) 2021 by Dreamwidth Studios, LLC.
#
# This program is free software; you may redistribute it and/or modify it under
# the same terms as Perl itself.  For a copy of the license, please reference
# 'perldoc perlartistic' or 'perldoc perlgpl'.
#

package DW::Task::SphinxCopier;

use strict;
use v5.10;
use Log::Log4perl;
my $log = Log::Log4perl->get_logger(__PACKAGE__);

use Carp qw/ croak /;
use Encode;

use DW::Task;
use DW::TaskQueue;

use base 'DW::Task';

sub sphinx_db {
    my $dbsx = LJ::get_dbh('sphinx_search')
        or $log->logcroak("Unable to connect to Sphinx search database.");

    # We have to use utf8 when we write to the db; Sphinx requires that data
    # actually be properly encoded.
    $dbsx->do(q{SET NAMES 'utf8'});
    $log->logcroak( $dbsx->errstr ) if $dbsx->err;
    return $dbsx;
}

sub work {
    my ( $self, $handle ) = @_;
    my $args = $self->args->[0];

    my $u = LJ::load_userid( $args->{userid} )
        or $log->logcroak("Invalid userid: $args->{userid}.");
    $log->info( "Sphinx copier started for "
            . $u->user . "("
            . $u->id
            . "), source "
            . ( $args->{source} // 'unknown' )
            . "." );
    return DW::Task::COMPLETED unless $u->is_person || $u->is_community;
    return DW::Task::COMPLETED if $u->is_expunged;

    # We copy comments for paid users, allowing them to search through the
    # comments to their journal.
    my $copy_comments = $u->is_paid ? 1 : 0;

    # There are several modes. Either we can do a full import (no arguments),
    # we can import a particular entry (edited or something), or we can import
    # a specific comment (again, edited or posted).
    #
    # We also can do ranges of entries or comments. (Typically used by jobs
    # that the recopier has broken down.)
    #
    # These are all best effort. If they fail, we don't do anything fancy and
    # assume that the next time the user posts or edits something, we'll end
    # up fixing up whatever was forgotten.
    if ( exists $args->{jitemid} ) {
        $log->info("Requested copy of only entry $args->{jitemid}.");
        copy_entry( $u, $args->{jitemid}, !$copy_comments );
    }
    elsif ( exists $args->{jtalkid} ) {
        $log->info("Requested copy of only comment $args->{jtalkid}.");
        copy_comment( $u, $args->{jtalkid} ) if $copy_comments;
    }
    elsif ( exists $args->{jitemids} ) {
        $log->info("Requested copy of entries @{$args->{jitemids}}.");
        copy_entry( $u, $args->{jitemids}, !$copy_comments );
    }
    elsif ( exists $args->{jtalkids} ) {
        $log->info("Requested copy of comments @{$args->{jtalkids}}.");
        copy_comment( $u, $args->{jtalkids} ) if $copy_comments;
    }
    else {
        $log->info("Requested complete recopy of user.");
        my $time = LJ::MemCache::get( [ $u->id, "sphinx-copy-full2:" . $u->id ] );
        if ( $time > time() - 86400 ) {
            $log->info("Copied less than a day ago. Skipping.");
            return DW::Task::COMPLETED;
        }
        LJ::MemCache::set( [ $u->id, "sphinx-copy-full2:" . $u->id ], time() );
        copy_entry( $u, undef, 1 );
        copy_comment($u) if $copy_comments;
    }

    return DW::Task::COMPLETED;
}

sub copy_comment {
    my ( $u, $only_jtalkid ) = @_;
    my $dbsx = sphinx_db()
        or $log->logcroak("Sphinx database not available.");
    my $dbfrom = LJ::get_cluster_master( $u->clusterid )
        or $log->logcroak("User cluster master not available.");

    # If the parameter is not an arrayref, then make it one if it's defined.
    $only_jtalkid = [$only_jtalkid]
        if defined $only_jtalkid && !ref $only_jtalkid;

    # A full comment import. We slice it by 1000 comment groups to make the
    # memory usage something that isn't insane. (This codepath exists because
    # of cfud and sixwordstories. Congrats!)
    if ( !defined $only_jtalkid ) {
        my $maxid = $dbfrom->selectrow_array( 'SELECT MAX(jtalkid) FROM talk2 WHERE journalid = ?',
            undef, $u->id );
        $log->logcroak( $dbfrom->errstr ) if $dbfrom->err;

        # If we have >1000 comments, we want to create jobs to do the importing so that
        # each individual job doesn't take too long
        if ( $maxid < 1000 ) {
            $log->info("Short path: doing mass-copy immediately.");
            copy_comment( $u, [ 1 .. $maxid ] );
            $log->info("Done with mass-copy.");
            return;
        }

        # Schedule jobs to do the copying
        my $n = 0;
        while ( $n < $maxid ) {
            my $m = $n + 1000;
            $m = $maxid if $m > $maxid;

            my $h = DW::TaskQueue->dispatch(
                DW::Task::SphinxCopier->new(
                    {
                        userid   => $u->id,
                        jtalkids => [ $n + 1 .. $m ],
                        source   => 'masscopy',
                    },
                )
            );
            $log->info(
                "Scheduled mass-copy job for jtalkids " . ( $n + 1 ) . " .. $m: handle = $h." );

            $n = $m;
        }
        $log->info("Done with mass-copy.");
        return;
    }

    my ( $entries,       $comments );
    my ( @copy_jitemids, @delete_jtalkids );
    my $allowpublic = $u->include_in_global_search ? 1 : 0;

    my $in = join ',', @$only_jtalkid;
    $comments = $dbfrom->selectall_hashref(
        qq{SELECT jtalkid, nodeid, state, posterid, UNIX_TIMESTAMP(datepost) AS 'datepost'
           FROM talk2 WHERE journalid = ? AND jtalkid IN ($in)},
        'jtalkid', undef, $u->id
    );
    $log->logcroak( $dbfrom->errstr ) if $dbfrom->err;
    return unless ref $comments eq 'HASH' && %$comments;

    # Now we have some comments, get data we need to build security for the
    # entries we're going to use.
    {
        my %jitemids;
        $jitemids{ $comments->{$_}->{nodeid} } = 1 foreach keys %$comments;
        my $inlist = join( ',', map { '?' } keys %jitemids );
        $entries = $dbfrom->selectall_hashref(
            qq{SELECT jitemid, security, allowmask FROM log2
                WHERE journalid = ? AND jitemid IN ($inlist)},
            'jitemid', undef, $u->id, keys %jitemids
        );
        $log->logcroak( $dbfrom->errstr ) if $dbfrom->err;

        foreach my $row ( values %$entries ) {

            # Auto-convert usemask-with-no-groups to private.
            $row->{security} = 'private'
                if $row->{security} eq 'usemask' && $row->{allowmask} == 0;

       # We need extra security bits for some metadata.  We have to do this this way because
       # it makes it easier to later do searches on various combinations of things at the same
       # time...  Also, even though these are bits, we're not going to ever use them as actual bits.
            my @extrabits;
            push @extrabits, 101 if $row->{security} eq 'private';
            push @extrabits, 102 if $row->{security} eq 'public';

            # have to do some more munging
            $row->{allowmask} = join ',', LJ::bit_breakdown( $row->{allowmask} ), @extrabits;
        }
    }

    # Comment loop.
    my @jtalkids;
    foreach my $jtalkid ( keys %$comments ) {
        my $state         = $comments->{$jtalkid}->{state};
        my $force_private = 0;                                # Override security to private.

        if ( $state eq 'D' ) {
            push @delete_jtalkids, int($jtalkid);
            next;
        }
        elsif ( $state eq 'S' || ( $state ne 'A' && $state ne 'F' ) ) {

            # If it's screened or in an unexpected state, make it private so
            # only owners can see it.
            $force_private = 1;
        }

        push @jtalkids, [ $jtalkid, $force_private ];
    }

    while ( my @items = splice( @jtalkids, 0, 1000 ) ) {
        last unless @items;

        my @l_jtalkids = map { $_->[0] } @items;
        my %private    = map { $_->[0] => $_->[1] } @items;
        my $in = join ',', @l_jtalkids;

        my $text = $dbfrom->selectall_hashref(
            qq{SELECT jtalkid, subject, body
               FROM talktext2 WHERE journalid = ? AND jtalkid IN ($in)},
            'jtalkid', undef, $u->id
        );
        $log->logcroak( $dbfrom->errstr ) if $dbfrom->err;

        foreach my $jtd ( keys %$text ) {
            my ( $subj, $body ) = ( $text->{$jtd}->{subject}, $text->{$jtd}->{body} );
            LJ::text_uncompress( \$subj );
            $text->{$jtd}->{subject} = Encode::decode( 'utf8', $subj );
            LJ::text_uncompress( \$body );
            $text->{$jtd}->{body} = Encode::decode( 'utf8', $body );
        }

        my $old_ids = $dbsx->selectall_hashref(
            qq{SELECT jtalkid, id FROM items_raw WHERE journalid = ? AND jtalkid IN ($in)},
            'jtalkid', undef, $u->id );
        $log->logcroak( $dbsx->errstr ) if $dbsx->err;

        foreach my $jid ( keys %$text ) {
            my $allowmask = $entries->{ $comments->{$jid}->{nodeid} }->{allowmask} // '101';
            $allowmask = '101' if $private{$jid};

            my $id = $old_ids->{$jid}->{id} || LJ::alloc_global_counter('X');
            if ( exists $old_ids->{$jid} ) {

                $log->info( "Updating comment #$jid for "
                        . $u->user . "("
                        . $u->id
                        . ") as Sphinx id $id." );
            }
            else {

                $log->info( "Inserting comment #$jid for "
                        . $u->user . "("
                        . $u->id
                        . ") as Sphinx id $id." );

            }

            $dbsx->do(
                q{REPLACE INTO items_raw (id, journalid, jtalkid, jitemid, poster_id,
                    date_posted, title, data, security_bits, allow_global_search, touchtime)
                VALUES (?, ?, ?, ?, ?, ?, ?, COMPRESS(?), ?, ?, UNIX_TIMESTAMP())},
                undef, $id, $u->id, $jid,
                ( map { $comments->{$jid}->{$_} } qw/ nodeid posterid datepost / ),
                $text->{$jid}->{subject}, $text->{$jid}->{body}, $allowmask, $allowpublic,
            );
            $log->logcroak( $dbsx->errstr ) if $dbsx->err;
        }
    }

    # deletes are easy...
    if (@delete_jtalkids) {
        my $ct = $dbsx->do(
            'DELETE FROM items_raw WHERE journalid = ? AND jtalkid IN ('
                . join( ',', @delete_jtalkids ) . ')',
            undef, $u->id
        ) + 0;
        $log->logcroak( $dbsx->errstr ) if $dbsx->err;

        $log->info("Actually deleted $ct comments.") if $ct > 0;
    }
}

sub copy_entry {
    my ( $u, $only_jitemid, $skip_comments ) = @_;
    my $dbsx = sphinx_db()
        or $log->logcroak("Sphinx database not available.");
    my $dbfrom = LJ::get_cluster_master( $u->clusterid )
        or $log->logcroak("User cluster master not available.");

    # If we're being asked to look at one post, that simplifies our processing
    # quite a bit.
    my ( $sphinx_times,  $db_times,        %comment_jitemids );
    my ( @copy_jitemids, @delete_jitemids, %sphinx_ids );

    if ($only_jitemid) {
        $sphinx_times = $dbsx->selectall_hashref(
            'SELECT id, jitemid FROM items_raw WHERE journalid = ? AND jitemid = ? AND jtalkid = 0',
            'jitemid', undef, $u->id, $only_jitemid
        );
        $log->logcroak( $dbsx->errstr ) if $dbsx->err;

        $db_times = $dbfrom->selectall_hashref(
            q{SELECT jitemid, UNIX_TIMESTAMP(logtime) AS 'createtime'
              FROM log2 WHERE journalid = ? AND jitemid = ?},
            'jitemid', undef, $u->id, $only_jitemid
        );
        $log->logcroak( $dbfrom->errstr ) if $dbfrom->err;
    }
    else {
        $sphinx_times = $dbsx->selectall_hashref(
            'SELECT id, jitemid FROM items_raw WHERE journalid = ? AND jtalkid = 0',
            'jitemid', undef, $u->id );
        $log->logcroak( $dbsx->errstr ) if $dbsx->err;

        $db_times = $dbfrom->selectall_hashref(
            q{SELECT jitemid, UNIX_TIMESTAMP(logtime) AS 'createtime'
              FROM log2 WHERE journalid = ?},
            'jitemid', undef, $u->id
        );
        $log->logcroak( $dbfrom->errstr ) if $dbfrom->err;
    }

    # This mostly just keeps track of the internal Sphinx document ID. We need to
    # keep that as stable as we can.
    foreach my $jitemid ( keys %$db_times ) {
        $sphinx_ids{$jitemid} = $sphinx_times->{$jitemid}->{id}
            if exists $sphinx_times->{$jitemid};
        push @copy_jitemids, $jitemid;
        $comment_jitemids{$jitemid} = 1;
    }

    # now find deleted posts
    foreach my $jitemid ( keys %$sphinx_times ) {
        next if exists $db_times->{$jitemid};

        $log->info("Deleting post #$jitemid.");
        push @delete_jitemids, $jitemid;
        $comment_jitemids{$jitemid} = 1;
    }

    # deletes are easy...
    if (@delete_jitemids) {
        my $ct = $dbsx->do(
            'DELETE FROM items_raw WHERE journalid = ? AND jtalkid = 0 AND jitemid IN ('
                . join( ',', @delete_jitemids ) . ')',
            undef, $u->id
        ) + 0;
        $log->logcroak( $dbsx->errstr ) if $dbsx->err;

        $log->info("Actually deleted $ct posts.");
    }

    # now to copy entries.  this is not done enmasse since the major case will be after a user
    # already has most of their posts copied and they are just updating one or two.
    foreach my $jitemid (@copy_jitemids) {
        my $row = $dbfrom->selectrow_hashref(
q{SELECT l.journalid, l.jitemid, l.posterid, l.security, l.allowmask, l.logtime, lt.subject, lt.event
              FROM log2 l INNER JOIN logtext2 lt ON (l.journalid = lt.journalid AND l.jitemid = lt.jitemid)
              WHERE l.journalid = ? AND l.jitemid = ?},
            undef, $u->id, $jitemid
        );
        $log->logcroak( $dbfrom->errstr ) if $dbfrom->err;

        # just make sure, in case we don't have a corresponding logtext2 row
        next unless $row;

        # Auto-convert usemask-with-no-groups to private.
        $row->{security} = 'private'
            if $row->{security} eq 'usemask' && $row->{allowmask} == 0;

       # we need extra security bits for some metadata.  we have to do this this way because
       # it makes it easier to later do searches on various combinations of things at the same
       # time...  also, even though these are bits, we're not going to ever use them as actual bits.
        my @extrabits;
        push @extrabits, 101 if $row->{security} eq 'private';
        push @extrabits, 102 if $row->{security} eq 'public';

        # have to do some more munging
        $row->{allowmask}   = join ',', LJ::bit_breakdown( $row->{allowmask} ), @extrabits;
        $row->{allowpublic} = $u->include_in_global_search ? 1 : 0;

        # very important, the search engine can't index compressed crap...
        foreach (qw/ subject event /) {
            LJ::text_uncompress( \$row->{$_} );

            # required, we store raw-bytes in our own database but the Sphinx system expects
            # things to be proper UTF-8, this does it.
            $row->{$_} = Encode::decode( 'utf8', $row->{$_} );
        }

        # insert
        my $id = $sphinx_ids{$jitemid} // LJ::alloc_global_counter('X');
        $dbsx->do(
            q{REPLACE INTO items_raw (id, journalid, jitemid, jtalkid, poster_id,
                security_bits, allow_global_search, date_posted, title, data, touchtime)
              VALUES (?, ?, ?, 0, ?, ?, ?, UNIX_TIMESTAMP(?), ?, COMPRESS(?), UNIX_TIMESTAMP())},
            undef, $id,
            map { $row->{$_} }
                qw/ journalid jitemid posterid
                allowmask allowpublic logtime subject event /
        );
        $log->logcroak( $dbsx->errstr ) if $dbsx->err;

        # let the viewer know what they missed
        $log->info(
            "Inserted post #$jitemid for " . $u->user . "(" . $u->id . ") as Sphinx id $id." );
    }

    unless ($skip_comments) {
        my %commentids;
        foreach my $jitemid ( keys %comment_jitemids ) {

            # Comments we know about (we do this so that we can delete them if they've
            # been removed).
            my $jtalkids = $dbsx->selectcol_arrayref(
q{SELECT jtalkid FROM items_raw WHERE journalid = ? AND jitemid = ? AND jtalkid > 0},
                undef, $u->id, $jitemid
            );
            $log->logcroak( $dbsx->errstr ) if $dbsx->err;

            if ( $jtalkids && ref $jtalkids eq 'ARRAY' ) {
                $commentids{$_} = 1 foreach @$jtalkids;
            }

            # And this catches comments that we don't know about yet.
            my $jtalkids2 = $dbfrom->selectcol_arrayref(
                q{SELECT jtalkid FROM talk2 WHERE journalid = ? AND nodetype = 'L' AND nodeid = ?},
                undef, $u->id, $jitemid
            );
            $log->logcroak( $dbsx->errstr ) if $dbsx->err;

            if ( $jtalkids2 && ref $jtalkids2 eq 'ARRAY' ) {
                $commentids{$_} = 1 foreach @$jtalkids2;
            }
        }
        copy_comment( $u, $_ ) foreach keys %commentids;
    }
}

1;
