package Article;
use strict;
use warnings;
use Mojo::DOM58;
use XML::Simple;
use Data::Dumper;
use IPC::Run 'run';
use Path::Tiny;
use List::Util 'none';
use JSON::XS;

my @stop_words = <DATA>;
my $json = JSON::XS->new->pretty->utf8;

sub new {
  my ($class, $args) = @_;

  preprocess_args($args);

  my $self = bless {
    %$args,
    rdf         => undef,
    draft       => undef,
    image       => undef,
    description => undef,
  }, $class;

  my $html = $self->{path}->slurp_utf8;
  $self->parse_rdf($html);
  $self->parse_html($html);

  return $self;
}

sub preprocess_args {
  my $args = shift;
  $args->{path} = path $args->{file};
  die "file not found $args->{file}" unless $args->{path}->is_file;

  # authors and tags are arrays of values
  $args->{authors} = split_column($args->{authors});
  $args->{tags} = split_tags($args->{tags});

  # date to datetime MM/DD/YYYY
  if ($args->{date} && $args->{date} =~ qr{(\d\d)/(\d\d)/(\d\d\d\d)}) {
    $args->{date} = "$3-$1-${2}T00:00:00-08:00";
  }

  # calculate slug
  if ($args->{file} =~ m{perl\.com(/pub/.+?)\.html$}) {
    $args->{slug} = $1;
  }
}

sub split_column {
  my $column = shift;
  my @values;
  if ($column) {
    @values = split /, | & | and /, $column;
    @values = map { s/\s{2,}/ /g;s/^\s+//; s/\s+$//;$_ } @values;
  }
  return \@values;
}

sub split_tags {
  my $column = lc(shift||'');
  my @tags;
  if ($column) {
    my @tokens = split /[,.& ]+/, $column;
    for my $t (@tokens) {
      $t =~ s/\:\:/-/g;
      next unless $t && $t =~ qr/a-z/i && none { $t eq $_ } @stop_words;
      push @tags, $t;
    }
  }
  return \@tags;
}

sub parse_rdf {
  my ($self, $html) = @_;
  if ($html =~ /^(<rdf:RDF .+?<\/rdf:RDF>)/sm) {
    my $rdf = $1;
    my $xml = XMLin($rdf);
    $self->{rdf} = $rdf;
    $self->{description} = $xml->{Work}{'dc:description'};

    # we may already have these values
    $self->{title} //= $xml->{Work}{'dc:title'};
    $self->{authors}[0] //= $xml->{Work}{'dc:creator'};
    $self->{slug} //= $xml->{Work}{'rdf:about'};

    # definitely override the date if we have a real datetime
    $self->{date} = $xml->{Work}{'dc:date'};
  }
  else {
    warn "rdf not found\n";
  }
}

sub parse_html {
  my ($self, $html) = @_;
  my $dom = Mojo::DOM58->new($html);
  $self->extract_metadata($dom);
  $self->extract_html($dom);
  $self->copy_graphics();
}

my $base_dir = '/home/dfarrell/Projects/perltricks-static/perlcom/perl.com';

sub copy_graphics {
  my ($self) = @_;

  my $parent = $self->{path}->parent;
  my $dom = Mojo::DOM58->new($self->{html});
  $dom->find('img')->each(sub {
      my $src = $_->attr('src');
      if (!$src) {
        warn "<img> no src\n";
        return;
      }
      elsif ($src =~ qr(^/pub)) {
        warn "img not found $src\n" unless -f "$base_dir${src}";
      }
      elsif ($src =~ qr(^/)) {
        warn "img not found $src\n" unless -f "$base_dir/pub$src";
      }
      elsif ($src !~ qr/^https?:\/\//i) {
        my $img_path = sprintf "%s/%s", $parent, $src;
        warn "img non-std location: $src\n" unless -f $img_path;
      }
    });
}
sub extract_html {
  my ($self, $dom) = @_;

  my $node = $dom->find('div.asset-body')->[0];

  unless ($node) {
    warn "body div not found\n";
    $node = $dom;
  }

  my $html = $node->to_string;
  unless ($html) {
    warn "failed to extract body html\n";
    return;
  }
  $self->{html} = $html;
}

sub to_markdown {
  my ($self) = @_;

  my ($html, $mkdn, $err) = ($self->{html});
  run [qw(pandoc -f html -t markdown)], \$html, \$mkdn, \$err;
  unless ($mkdn) {
    warn 'failed to convert to markdown: ' . ($err||'unknown error');
    return;
  }

  # rm top and tail div tags
  $mkdn =~ s/^<div class="asset-body">//;
  $mkdn =~ s/<\/div>$//;
  return $mkdn;
}

sub filepath {
  my $self = shift;
  my $filepath = $self->{slug} =~ s{/}{_}gr;
  return "$filepath.md";
}

sub front_matter {
  my $self = shift;
  return {
    title => $self->{title},
    date  => $self->{date},
    authors => $self->{authors},
    tags    => $self->{tags},
    categories => $self->{categories},
    draft => $self->{draft},
    image => $self->{image},
    description => $self->{description},
    slug => $self->{slug},
  };
}

sub serialize {
  my $self = shift;
  return join "\n\n\n", $json->encode($self->front_matter), $self->to_markdown;
}

# if rdf extraction failed, try getting the data from the HTML
sub extract_metadata {
  my ($self, $dom) = @_;
  $self->extract_title($dom);
  $self->extract_author($dom);
  $self->extract_date($dom);
  $self->extract_slug($dom);
  $self->extract_tags($dom);
}

sub extract_title {
  my ($self, $dom) = @_;

  unless ($self->{title}) {
    if (my $title = $dom->find('title')->[0]) {
      $self->{title} = $title->text;
    }
    elsif (my $h1 = $dom->find('h1')->[0]) {
      # some headers have embedded links
      if (my $text = $h1->text) {
        $self->{title} = $text;
      }
      elsif (my $a = $h1->find('a')->[0]) {
        $self->{title} = $a->text;
      }
    }
    warn "unable to extract article title\n" unless $self->{title};
  }
}

sub extract_author {
  my ($self, $dom) = @_;

  unless (@{$self->{authors}}) {
    if (my $span = $dom->find('span[vcard author]')->[0]) {
      $self->{authors} = [ $span->text ];
    }
  }
  warn "unable to extract author\n" unless @{$self->{authors}} && $self->{authors}[0];
}

sub extract_date {
  my ($self, $dom) = @_;

  unless ($self->{date}) {
    if (my $abbr = $dom->find('abbr.published')->[0]) {
     $self->{date} = $abbr->attr('title');
    }
    # use the filepath if it contains a whole date
    elsif ($self->{path} =~ qr/(\d{4})\/(\d{2})\/(\d{2})/) {
      $self->{date} = "$1-$2-$3T00:00:00-08:00";
    }
  }
  warn "unable to extract date\n" unless $self->{date};
}

sub extract_slug {
  my ($self, $dom) = @_;

  unless ($self->{slug}) {
    # use the filepath as the slug
    if ($self->{path}->absolute =~ qr/(\/pub\/.+)$/) {
      $self->{slug} = $1;
    }
  }
  warn "unable to extract slug\n" unless $self->{slug};
}

sub extract_tags {
  my ($self, $dom) = @_;
  unless (@{$self->{tags}}) {
    my @tags;
    $dom->find('div.entry-tags a')->each(sub { push @tags, format_tag($_->text) });
    warn "no tags found\n" unless scalar @tags;
    $self->{tags} = \@tags;
  }
}

sub format_tag {
  my $txt = shift;
  $txt = lc $txt;
  $txt =~ s/[^a-z0-9]/-/g;
  $txt =~ s/-{2,}/-/g;
  $txt =~ s/^-//;
  $txt =~ s/-$//;
  return $txt;
}

sub has_required {
  my $self = shift;
  return 4 == grep( $self->{$_}, qw(title date slug html) )
    && scalar @{$self->{authors}};
}

1;
__DATA__
about
above
across
after
again
against
all
almost
alone
along
already
also
although
always
among
an
and
another
any
anybody
anyone
anything
anywhere
are
area
areas
around
as
ask
asked
asking
asks
at
away
b
back
backed
backing
backs
be
became
because
become
becomes
been
before
began
behind
being
beings
best
better
between
big
both
but
by
c
came
can
cannot
case
cases
certain
certainly
clear
clearly
come
could
d
did
differ
different
differently
do
does
done
down
down
downed
downing
downs
during
e
each
early
either
end
ended
ending
ends
enough
even
evenly
ever
every
everybody
everyone
everything
everywhere
f
face
faces
fact
facts
far
felt
few
find
finds
first
for
four
from
full
fully
further
furthered
furthering
furthers
g
gave
general
generally
get
gets
give
given
gives
go
going
good
goods
got
great
greater
greatest
group
grouped
grouping
groups
h
had
has
have
having
he
her
here
herself
high
high
high
higher
highest
him
himself
his
how
however
i
if
important
in
interest
interested
interesting
interests
into
is
it
its
itself
j
just
k
keep
keeps
kind
knew
know
known
knows
l
large
largely
last
later
latest
least
less
let
lets
like
likely
long
longer
longest
m
made
make
making
man
many
may
me
member
members
men
might
more
most
mostly
mr
mrs
much
must
my
myself
n
necessary
need
needed
needing
needs
never
new
new
newer
newest
next
no
nobody
non
noone
not
nothing
now
nowhere
number
numbers
o
of
off
often
old
older
oldest
on
once
one
only
open
opened
opening
opens
or
order
ordered
ordering
orders
other
others
our
out
over
p
part
parted
parting
parts
per
perhaps
place
places
point
pointed
pointing
points
possible
present
presented
presenting
presents
problem
problems
put
puts
q
quite
r
rather
really
right
right
room
rooms
s
said
same
saw
say
says
second
seconds
see
seem
seemed
seeming
seems
sees
several
shall
she
should
show
showed
showing
shows
side
sides
since
small
smaller
smallest
so
some
somebody
someone
something
somewhere
state
states
still
still
such
sure
t
take
taken
than
that
the
their
them
then
there
therefore
these
they
thing
things
think
thinks
this
those
though
thought
thoughts
three
through
thus
to
today
together
too
took
toward
turn
turned
turning
turns
two
u
under
until
up
upon
us
use
used
uses
v
very
w
want
wanted
wanting
wants
was
way
ways
we
well
wells
went
were
what
when
where
whether
which
while
who
whole
whose
why
will
with
within
without
work
worked
working
works
would
x
y
year
years
yet
you
young
younger
youngest
your
yours
z