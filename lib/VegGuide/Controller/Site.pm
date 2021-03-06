package VegGuide::Controller::Site;

use strict;
use warnings;
use namespace::autoclean;

use VegGuide::Geocoder;
use VegGuide::Location;
use VegGuide::NewsItem;
use VegGuide::Search::Vendor::ByLatLong;
use VegGuide::Search::Vendor::ByName;
use VegGuide::SiteURI qw( entry_uri news_item_uri region_uri );
use VegGuide::SurveyResponse2008001;
use VegGuide::Util qw( string_is_empty );
use VegGuide::Vendor;

use Moose;

BEGIN { extends 'VegGuide::Controller::DirectToView'; }

with 'VegGuide::Role::Controller::Feed';

sub feed : LocalRegex('^recent.(atom|rss)') {
    my $self = shift;
    my $c    = shift;
    my $type = $c->request()->captures()->[0];

    my $method
        = $c->request()->param('reviews_only') ? 'NewReviewsFeed'
        : $c->request()->param('entries_only') ? 'NewVendorsFeed'
        :                                        'NewVendorsAndReviewsFeed';

    my $feed = VegGuide::Location->$method();

    $self->_serve_feed( $c, $feed, $type );
}

sub data_feed : Path('/site.rss') {
    my $self = shift;
    my $c    = shift;

    my $site_rss = File::Spec->catfile( VegGuide::Config->CacheDir(), 'rss',
        'site.rss' );

    $self->_serve_rss_data_file( $c, $site_rss );
}

sub new_region_form : Local {
    my $self = shift;
    my $c    = shift;

    $c->redirect_and_detach('/')
        unless $c->vg_user()->is_admin();

    $c->stash()->{template} = '/site/new-region-form';
}

sub duplicate_resolution_form : Local {
    my $self = shift;
    my $c    = shift;

    $self->_require_auth(
        $c,
        q{You must be logged in to add a new region. If you don't have an account you can create one now.},
    );

    my %data = $c->request()->location_data();
    $data{parent_location_id} = $c->request()->param('parent_location_id');

    $c->stash()->{locations} = [
        VegGuide::Location->ByNameOrCityName( name => $data{name} )->all() ];
    $c->stash()->{params} = \%data;

    $c->stash()->{template} = '/site/duplicate-resolution-form';
}

sub clone_entry_form : Local {
    my $self = shift;
    my $c    = shift;

    $self->_require_auth(
        $c,
        q{You must be logged in to clone an entry. If you don't have an account you can create one now.},
    );

    my $vendor_id = $c->request()->param('vendor_id') || 0;

    my $vendor = VegGuide::Vendor->new( vendor_id => $vendor_id );

    $c->redirect_and_detach('/')
        unless $vendor;

    $c->stash()->{vendor} = $vendor;

    $c->stash()->{template} = '/site/clone-entry-form';
}

{

    # It would be clever to infer a country from a postal code, if
    # possible. For now, we only handle country-less addresses in the
    # US and Canada (since Google just works when given a Canadian
    # postal code).
    my $PostalCodeRe = qr/ (?: \d{5} (?:-\d{4})?     # US - zip (+4)
                               |
                               \w\d\w(?:\s+\d\w\d)?  # Canada
                               |
                               (?:                   # UK
                                ^
                                [a-z][0-9]\ [0-9][a-z]{2}
                                |
                                [a-z][0-9]{2}\ [0-9][a-z]{2}
                                |
                                [a-z]{2}[0-9]\ [0-9][a-z]{2}
                                |
                                [a-z]{2}[0-9]{2}\ [0-9][a-z]{2}
                                |
                                [a-z][0-9][a-z]\ [0-9][a-z]{2}
                                |
                                [a-z]{2}[0-9][a-z]\ [0-9][a-z]{2}
                                $
                               )
#                               |
#                               \d{4}\w\w             # Netherlands
#                               |
#                               \d{4,}                # Australia, Singapore, many others
                            )
                         /xism;

    sub search : Local {
        my $self = shift;
        my $c    = shift;

        my $text = $c->request()->param('search_text');
        $text =~ s/^\s+|\s+$// if defined $text;

        $c->redirect_and_detach('/')
            if string_is_empty($text);

        my $looks_like_address = 0;

        unless ( $c->request()->param('name_only') ) {
            # Text contains some sort of postal code, possibly followed by
            # a country name. _Or_ it has > 1 comma, in which case it
            # pretty much has to be an address (I hope).
            $looks_like_address = 1
                if $text =~ /$PostalCodeRe (?:, \s* \D+)?$/xism
                || $text =~ tr/,/,/ > 1;
        }

        # This handles things like "2600 Emerson Ave S, Minneapolis MN"
        if (  !$looks_like_address
            && $text =~ tr/,/,/ == 1
            && $text =~ /,\s*\S+\s+(?!$PostalCodeRe)$/ ) {
            my @locations
                = VegGuide::Location->ByNameOrCityName( name => $text )
                ->all();
            my $search
                = VegGuide::Search::Vendor::ByName->new( name => $text );
            my $vendor_count = $search->count();

            unless ( @locations || $vendor_count ) {
                $text =~ s/\s+(\S+)$/, $1/;
                $looks_like_address = 1;
            }
        }

        if ($looks_like_address) {
            return $self->_search_by_address( $c, $text );
        }
        else {
            return $self->_search_by_name( $c, $text );
        }
    }
}

sub _search_by_name {
    my $self        = shift;
    my $c           = shift;
    my $search_text = shift;

    my $name;
    my $parent;

    # Could be something like "Portland, OR" in which case we want
    # to find the appropriate region (if one exists).
    if ( $search_text =~ /^([^,\d]+)\s*,\s*([^,\d]+)$/ ) {
        $name   = $1;
        $parent = $2;
    }

    my %p = ( name => $name || $search_text );
    $p{parent} = $parent if defined $parent;

    my @locations = VegGuide::Location->ByNameOrCityName(%p)->all();

    my $search;
    my $vendor_count = 0;

    unless ($parent) {
        $search = VegGuide::Search::Vendor::ByName->new( name => $name
                || $search_text );
        $vendor_count = $search->count();
    }

    if ( @locations == 1 && $vendor_count == 0 ) {
        $c->response()->redirect( region_uri( location => $locations[0] ) );
    }
    elsif ( @locations == 0 && $vendor_count == 1 ) {
        my $vendor = $search->vendors()->next();
        $c->response()->redirect( entry_uri( vendor => $vendor ) );
    }
    elsif ( @locations == 0 && $vendor_count > 1 ) {
        $c->response()->redirect( $search->uri() );
    }

    $c->stash()->{search_text} = $search_text;
    $c->stash()->{locations}   = \@locations;

    if ($search) {
        $search->set_cursor_params( limit => 5 );
        $c->stash()->{vendors}       = $search->vendors();
        $c->stash()->{vendor_search} = $search;
        $c->stash()->{vendor_count}  = $vendor_count;
    }

    $c->stash()->{template} = '/site/search-results';
}

sub _search_by_address {
    my $self = shift;
    my $c    = shift;
    my $text = shift;

    my $country = ( split /,\s*/, $text )[-1];
    my $geocoder = VegGuide::Geocoder->new( country => $country );

    my $result = $geocoder->geocode_full_address($text);

    unless ($result) {
        $c->stash()->{search_text} = $text;
        $c->stash()->{template}    = '/site/address-search-failed';

        return;
    }

    # XXX - this should probably be a user-settable preference as well
    my $unit = $result->country_code() =~ /^(?:US|GB)/ ? 'mile' : 'km';

    my $search = VegGuide::Search::Vendor::ByLatLong->new(
        address   => $text,
        unit      => $unit,
        latitude  => $result->latitude(),
        longitude => $result->longitude(),
    );

    $c->response()->redirect( $search->uri() );
}

sub news : Local : ActionClass('+VegGuide::Action::REST') {
}

sub news_GET_html : Private {
    my $self = shift;
    my $c    = shift;

    my $page  = $c->request()->param('page') || 1;
    my $limit = 10;
    my $start = ( $page - 1 ) * $limit;

    my $total = VegGuide::NewsItem->Count();

    $c->redirect_and_detach('/')
        if $start > $total;

    $c->stash()->{news} = VegGuide::NewsItem->All(
        limit => $limit,
        start => $start,
    );

    $c->stash()->{pager} = VegGuide::Pageset->new(
        {
            total_entries    => $total,
            entries_per_page => $limit,
            current_page     => $page,
            pages_per_set    => 1,
        },
    );

    $c->stash()->{template} = '/site/news';
}

sub news_POST : Private {
    my $self = shift;
    my $c    = shift;

    $c->redirect_and_detach('/')
        unless $c->vg_user()->is_admin();

    my $params = $c->request()->parameters();

    VegGuide::NewsItem->create(
        title => $params->{title},
        body  => $params->{body},
    );

    $c->add_message('News item added.');

    $c->redirect_and_detach('/site/news');
}

sub news_item : LocalRegex('^news/(\d+)$') :
    ActionClass('+VegGuide::Action::REST') {
}

sub news_item_PUT : Private {
    my $self = shift;
    my $c    = shift;

    $c->redirect_and_detach('/')
        unless $c->vg_user()->is_admin();

    my $item = VegGuide::NewsItem->new(
        item_id => $c->request()->captures()->[0] );

    $c->redirect_and_detach('/')
        unless $item;

    my $params = $c->request()->parameters();

    $item->update(
        title => $params->{title},
        body  => $params->{body},
    );

    $c->add_message('News item updated.');

    $c->redirect_and_detach('/site/news');
}

sub news_item_DELETE : Private {
    my $self = shift;
    my $c    = shift;

    $c->redirect_and_detach('/')
        unless $c->vg_user()->is_admin();

    my $item = VegGuide::NewsItem->new(
        item_id => $c->request()->captures()->[0] );

    $c->redirect_and_detach('/')
        unless $item;

    $item->delete();

    $c->add_message('News item deleted.');

    $c->redirect_and_detach('/site/news');
}

sub news_item_edit_form : LocalRegex('^news/(\d+)/edit_form$') {
    my $self = shift;
    my $c    = shift;

    $c->redirect_and_detach('/')
        unless $c->vg_user()->is_admin();

    my $item = VegGuide::NewsItem->new(
        item_id => $c->request()->captures()->[0] );

    $c->redirect_and_detach('/')
        unless $item;

    $c->stash()->{item} = $item;

    $c->stash()->{template} = '/site/news-item-edit-form';
}

sub news_item_deletion_confirmation :
    LocalRegex('^news/(\d+)/deletion_confirmation_form$') {
    my $self = shift;
    my $c    = shift;

    $c->redirect_and_detach('/')
        unless $c->vg_user()->is_admin();

    my $item = VegGuide::NewsItem->new(
        item_id => $c->request()->captures()->[0] );

    $c->stash()->{thing} = 'news item';
    $c->stash()->{name}  = $item->title();

    $c->stash()->{uri} = news_item_uri( item => $item );

    $c->stash()->{template} = '/shared/deletion-confirmation-form';
}

sub survey_2008_1_summary : Local {
    my $self = shift;
    my $c    = shift;

    $c->stash()->{total} = VegGuide::SurveyResponse2008001->Count();
    $c->stash()->{visit_frequency}
        = VegGuide::SurveyResponse2008001->VisitFrequencies();
    $c->stash()->{diet}       = VegGuide::SurveyResponse2008001->Diets();
    $c->stash()->{activities} = VegGuide::SurveyResponse2008001->Activities();
    $c->stash()->{features}   = VegGuide::SurveyResponse2008001->Features();
    $c->stash()->{other}      = VegGuide::SurveyResponse2008001->OtherSites();

    $c->stash()->{template} = '/site/survey-2008-1-summary';
}

sub survey_2008_1_details : Local {
    my $self = shift;
    my $c    = shift;

    $c->stash()->{total} = VegGuide::SurveyResponse2008001->Count();
    $c->stash()->{other_sites}
        = VegGuide::SurveyResponse2008001->OtherSitesOther();
    $c->stash()->{improvements}
        = VegGuide::SurveyResponse2008001->Improvements();

    $c->stash()->{template} = '/site/survey-2008-1-details';
}

__PACKAGE__->meta()->make_immutable();

1;
