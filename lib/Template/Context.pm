#============================================================= -*-Perl-*-
#
# Template::Context
#
# DESCRIPTION
#   Module defining a context in which a template document is processed.
#   This is the runtime processing environment in which a template "runs"
#   and through which it can be controlled.
#
# AUTHOR
#   Andy Wardley   <abw@cre.canon.co.uk>
#
# COPYRIGHT
#   Copyright (C) 1996-1999 Andy Wardley.  All Rights Reserved.
#   Copyright (C) 1998-1999 Canon Research Centre Europe Ltd.
#
#   This module is free software; you can redistribute it and/or
#   modify it under the same terms as Perl itself.
# 
#----------------------------------------------------------------------------
#
# $Id: Context.pm,v 1.34 1999/11/03 01:20:30 abw Exp $
#
#============================================================================

package Template::Context;

require 5.004;

use strict;
use vars qw( $VERSION $DEBUG $CATCH_VAR );
use Template::Constants qw( :status :error :ops :template );
use Template::Utils qw( :subs );
use Template::Cache;
use Template::Stash;


$VERSION   = sprintf("%d.%02d", q$Revision: 1.34 $ =~ /(\d+)\.(\d+)/);
$DEBUG     = 0;
$CATCH_VAR = 'error';


#========================================================================
#                  ----- RUNTIME BINARY OPS -----
#========================================================================

my $binop  = {
    '=='  => sub { local $^W = 0; $_[0] eq $_[1] ? 1 : 0 },
    '!='  => sub { local $^W = 0; $_[0] ne $_[1] ? 1 : 0 },
    '<'   => sub { local $^W = 0; $_[0] <  $_[1] ? 1 : 0 },
    '<='  => sub { local $^W = 0; $_[0] <= $_[1] ? 1 : 0 },
    '>'   => sub { local $^W = 0; $_[0] >  $_[1] ? 1 : 0 },
    '>='  => sub { local $^W = 0; $_[0] >= $_[1] ? 1 : 0 },
#    '&&'  => sub { $_[0] && $_[1] ? 1 : 0 },
#    '||'  => sub { $_[0] || $_[1] ? 1 : 0 },
};


#========================================================================
#                     -----  PUBLIC METHODS -----
#========================================================================

#------------------------------------------------------------------------
# new(\%config)
#
# Constructor method which creates and initialised a new Template::Context
# object, using the optional configuration hash passed by reference.
# The method creates Template::Cache and Template::Stash objects to 
# manage templates and variables respectively.  Output and error handlers
# are constructed via calls to output_handler().
#------------------------------------------------------------------------

sub new {
    my $class  = shift;
    my $params = shift || { };
    my ($cache, $stash, $pbase, $predefs) = 
	@$params{ qw( CACHE STASH PLUGIN_BASE PRE_DEFINE ) };


    # stash is constructed with any PRE_DEFINE variables;
    # we add a 'global' namespace for convenience
    $predefs->{'global'} ||=  { };
    $stash ||= Template::Stash->new($predefs);

    # CACHE can be either an option to the Template::Cache->new() 
    # constructor or a cache object reference
    $cache = Template::Cache->new($params)
	unless ref $cache;
    
    # PLUGIN_BASE is a single directory or array ref (may also be undef)
    $pbase = ref $pbase eq 'ARRAY' 
	     ?   $pbase 
	     : [ $pbase || 'Template::Plugin'];

    my $self = bless {
	STASH        => $stash,
	CACHE        => $cache,
	PLUGIN_BASE  => $pbase,
	PLUGINS      => $params->{ PLUGINS } || { },
	CATCH        => $params->{ CATCH }   || { },
	FILTERS      => $params->{ FILTERS } || { },
        FILTER_CACHE => { },
        OUTPUT_PATH  => $params->{ OUTPUT_PATH } || '.',
	RECURSION    => $params->{ RECURSION }   || 0,
	DEBUG        => $params->{ DEBUG }       || 0,
    }, $class;

    $self->redirect(TEMPLATE_OUTPUT, $params->{ OUTPUT });
    $self->redirect(TEMPLATE_ERROR,  $params->{ ERROR } || \*STDERR);

    $self;
}


#------------------------------------------------------------------------
# old()
# 
# Destructor method called to undefine all hash members to break any 
# circular references that may exist. 
#------------------------------------------------------------------------

sub old {
    my $self = shift;
    undef %$self;
}


#------------------------------------------------------------------------
# process($template) 
#
# This is the main template processing method.
#
# The parameter should indicate the template source and should be a
# scalar (filename), scalar ref (text) or a GLOB or IO::Handle from
# which the template should be read.  Reading the template source is
# handled by calling the CACHE fetch() method.  Alternatively, $input
# may reference a Template::Directive object or sublass thereof which
# will be processed directly, bypassing the cache.
#
# The template is processed in the current context.  The method marks
# templates as "hot" while they are being processed to help identify
# recursion.  The return value is a status code or exception which 
# will be undefined or 0 (STATUS_OK) if the template processed without
# any (uncaught) errors.
#------------------------------------------------------------------------

sub process {
    my ($self, $template) = @_;
    my $no_recurse = ! $self->{ RECURSION };
    my $error;

    # request compiled template from cache
    $template = $self->{ CACHE }->fetch($template)
	|| return $self->throw($self->{ CACHE }->error())   ## RETURN ##
	    unless UNIVERSAL::isa($template, 'Template::Directive');

    # check we're not already visiting this template
    return $self->throw(ERROR_FILE, "recursion into '$template' identified")
	if $no_recurse && $self->{ VISITING }->{ $template };   ## RETURN ##

    # mark template as being visited
    $self->{ VISITING }->{ $template } = 1;

    # process template
    $error = $template->process($self);

    # a STATUS_RETURN is caught and cleared as this represents the 
    # correct point for a [% RETURN %] to return to
    $error = STATUS_OK 
	if $error == STATUS_RETURN;

    # clear visitation flag
    undef $self->{ VISITING }->{ $template };

    return $error;
}


#------------------------------------------------------------------------
# localise(\%params)
# delocalise()
#
#
# The localise() method creates a local "copy" of the current context.
# The delocalise() method restores the original context.  At present,
# the localisation process consists of "cloning" the stash to create a
# new copy of the main variable namespace.  A subsequent declone(),
# performed by the delocalise(), restores the variables to their
# values prior to cloning.  Used by Template module and INCLUDE
# directive.
#
# A reference to a hash array may be passed containing local variable 
# definitions which should be added to the cloned namespace.  These 
# values persist until de-localisation.
#------------------------------------------------------------------------

sub localise {
    my ($self, $params) = @_;

    # clone internal stash to localise new variables
    $self->{ STASH } = $self->{ STASH }->clone($params);
}

sub delocalise {
    my $self = shift;

    # restore original stash
    $self->{ STASH } = $self->{ STASH }->declone();
}



#------------------------------------------------------------------------
# throw($type, $info)
# throw($exception)
#
# This method is called to raise an error condition (throw an exception)
# within the context.  An exception object is a simple structure which 
# contains a type to indicate the error (e.g. 'file', 'undef') and an
# information string to represent the error condition (e.g. 'foobar:
# file not found').  This method may be called by passing in a reference
# to a Template::Exception object or the type and information parameters 
# separately.
# 
# The exception type is used to key into the $self->{ CATCH } hash
# to determine how to handle this kind of error.  The default key 
# 'default' is also tried.  Any defined value will be returned to the 
# caller.  If no CATCH entry is found, $exception will be returned
# as is, or an exception will be constructed from $type and $info and 
# returned.
#
#------------------------------------------------------------------------

sub throw {
    my ($self, $type, $info) = @_;
    my $handlers = $self->{ CATCH };
    my ($exception, $catch, $catchref);


    # grok params which may be ($exception) or ($type, $info)
    if (ref $type eq 'Template::Exception') {
	# the first parameter may be an exception from which we extract 
	# the type and info.  If the exception has already been thrown 
	# then we simple return it.
	$exception = $type;
	$type = $exception->type();
	$info = $exception->info();
	$exception->thrown(1);
    }

    # look for specific, then default throw definition
    $catch = $handlers->{ $type };
    $catch = $handlers->{'default'}
	unless defined $catch;

    # THROWING is used to avoid recursive throws (i.e. disable interupts)
    return STATUS_OK
	if $self->{ THROWING }->{ $type };
	
    $self->{ THROWING }->{ $type } = 1;

    # call sub-routine if $catch is a CODE ref
    if (($catchref = ref($catch)) eq 'CODE') {
	$catch = &$catch($self, $type, $info);
    }
    # call process() to render a Template::Directive reference
    elsif ($catchref && UNIVERSAL::isa($catch, 'Template::Directive')) {
	# localise context and provide access to error info via 'e'
	$self->localise({ 'e' => { 'type' => $type, 'info' => $info } });
	$catch = $self->process($catch);
	$self->delocalise();
    }
    
    undef $self->{ THROWING }->{ $type };
	    
    # create an exception if $catch is still undefined
    $catch = $catch || Template::Exception->new($type, $info, 1)
	unless defined $catch;
	
    return $catch;
}


#------------------------------------------------------------------------
# catch($type, $handler) 
#
# Installs the exception handler, $handler, in the internal CATCH lookup
# table for exceptions of $type.
#
# Returns STATUS_OK or a Template::Exception on error.
#------------------------------------------------------------------------

sub catch {
    my ($self, $type, $handler) = @_;
    $type ||= 'default';
    $self->{ CATCH }->{ $type } = $handler;
    return STATUS_OK;
}



#------------------------------------------------------------------------
# use_plugin($name, \@params) 
#
# Called by the USE directive to instantiate a new plugin object, 
# indicated by $name.  The optional second parameter may contain a 
# reference to a list of parameters passed to the USE directive.
# Attempts to load the required module by prefixing the value(s) 
# of PLUGIN_BASE and converting any periods to '::', or by using a 
# predefined lookup for $name from $Template::Plugin::PLUGIN_NAMES.
# 
# Returns a new plugin object instance.
#------------------------------------------------------------------------

sub use_plugin {
    my ($self, $name, $params) = @_;
    my ($factory, $module, $base, $package, $filename, $plugin, $ok);

    require Template::Plugin;

    # we may have already loaded the module and obtained a factory name/obj
    unless (defined ($factory = $self->{ PLUGINS }->{ $name })) {

	# module name is built from $name unless defined in PLUGIN_NAME hash
	($module = $name) =~ s/\./::/g
	    unless defined($module = 
			   $Template::Plugin::PLUGIN_NAMES->{ $name });

	foreach $base (@{ $self->{ PLUGIN_BASE } }) {
	    $package =  $base . '::' . $module;
	    ($filename = $package) =~ s|::|/|g;
	    $filename .= '.pm';

	    $ok = eval { require $filename };
	    last unless $@;
	}
	return (undef, Template::Exception->new(ERROR_UNDEF,
			"failed to load plugin module $name"))
	    unless $ok;

	$factory = eval { $package->load($self) };
	return (undef, Template::Exception->new(ERROR_UNDEF, 
			"failed to initialise plugin module $name"))
	    if $@ || ! $factory;

	$self->{ PLUGINS }->{ $name } = $factory;
    }

    # call the new() method on the factory object or class name
    eval {
	$plugin = $factory->new($self, @{ $params || [] })
	    || die "$name plugin: ", $factory->error(), "\n";
    };
    return (undef, Template::Exception->new(ERROR_UNDEF, $@))
	if $@;

    return $plugin;
}



#------------------------------------------------------------------------
# use_filter($name, \@params, $alias) 
#
# Called by the FILTER directive to request a filter sub-routine.
# Calls use_plugin() to request a filter plugin type, passing the 
# filter name and params.  Filters specified without any parameters
# will be cached by their name or a provided alias.  Filters that
# have parameters will only be cached if an alias is provided.
#
# Returns a CODE reference representing the filter.
#------------------------------------------------------------------------

sub use_filter {
    my ($self, $name, $params, $alias) = @_;
    my ($filter, $factory, $args, $error);
    
    # use any cached version of the filter if no params provided
    $filter = $self->{ FILTER_CACHE }->{ $name }
	unless ($params);

    # load the Filter plugin, if not already loaded
    $self->{ FILTER_PLUGIN } ||= do {
	require Template::Filters;
        Template::Filters->register($self);
    };

    unless ($filter) {
	# prepare filter arguments
	$args = $params || [];

	# extract the filter factory from FILTERS
	return (undef, Template::Exception->new(ERROR_UNDEF,
						"unknown FILTER '$name'"))
	    unless $factory = $self->{ FILTERS }->{ $name };

	
	return (undef, Template::Exception->new(ERROR_UNDEF,
		       "invalid FILTER factory for '$name' (not a CODE ref)"))
	    unless ref($factory) eq 'CODE';

	($filter, $error) = &$factory(@$args);
	return (undef, $error)
	    if $error;
    }
    return (undef, Template::Exception->new(ERROR_UNDEF,
				    "invalid FILTER '$name' (not a CODE ref)"))
	unless ref($filter) eq 'CODE';

    # alias defaults to name iff no parameters were supplied
    $alias = $name
	unless $params || defined $alias;

    # cache FILTER if alias is valid
    $self->{ FILTER_CACHE }->{ $alias } = $filter
	if $alias;

    return ($filter, Template::Constants::STATUS_OK);
} 



#------------------------------------------------------------------------
# register_filter($filter_name, $factory)
#
# Allows plugins to register filter factories that they define.
#------------------------------------------------------------------------

sub register_filter {
    my ($self, $filter, $factory) = @_;
    $self->{ FILTERS }->{ $filter } = $factory;
}



#------------------------------------------------------------------------
# redirect($what, $where)
#
# Called to set OUTPUT, ERROR or DEBUG output ($what) to a new location
# ($where).  See Template::Utils::output_handler() for details of what 
# $where can can be.  Returns a reference to the previous handler or
# undef.
#------------------------------------------------------------------------

sub redirect {
    my ($self, $what, $where) = @_;
    my ($previous, $output, $error, $reftype);
    
    # default output stream to 'OUTPUT'
    $what = Template::Constants::TEMPLATE_OUTPUT
	unless defined $what;

    $what = uc $what;
    return undef
	unless $what =~ /^OUTPUT|ERROR$/;
    
    # default OUTPUT to STDOUT, anything else to STDERR
    $where = $what eq Template::Constants::TEMPLATE_OUTPUT
	     ? \*STDOUT
	     : \*STDERR
	unless defined $where;

    # save previous handler
    $previous = $self->{ $what };

    # if $where is a string representing a filename, we prepend OUTPUT_PATH
    $where = $self->{ OUTPUT_PATH } . '/' . $where
	unless ref($where);

    # set handler internally
    ($self->{ $what }, $error) = (Template::Utils::output_handler($where));
    $self->error($error)
	if $error;

    # return previous handler
    $previous;
}



#------------------------------------------------------------------------
# output(...) 
#
# Calls the internal OUTPUT code sub, , as established by redirect(), 
# passing all parameters.
#------------------------------------------------------------------------

sub output {
    my $self = shift;
    &{ $self->{ OUTPUT } }(@_);
}



#------------------------------------------------------------------------
# error(...) 
#
# Calls the internal ERROR code sub, as established by redirect(), 
# passing all parameters.
#------------------------------------------------------------------------

sub error {
    my $self = shift;
    &{ $self->{ ERROR } }(@_);
}


sub DESTROY {
    my $self = shift;
    undef $self->{ STASH };
}


#========================================================================
#                      -----  PRIVATE METHODS -----
#========================================================================

#------------------------------------------------------------------------
# _evaluate(\@ops, $type)
#
# \@ops is a list of opcodes interpreted as [ @ops ]
# $type is an optional param to indicate that the list is to be 
# interpreted in a particular way, i.e. as [ $type, \@ops ]
# The method implements a Finite State Machine which runs the 
# sequence of opcodes and returns the result.
#------------------------------------------------------------------------

my $list_ops = {
    'max'  => sub { local $^W = 0; my $item = shift; $#$item; },
    'size' => sub { local $^W = 0; my $item = shift; $#$item + 1; },
    'sort' => sub { my $item = shift; [ sort @$item ] },
};

my $hash_ops = {
    'keys'   => sub { [ keys   %{ $_[0] } ] },
    'values' => sub { [ values %{ $_[0] } ] },
};

my $root_ops = {
    'inc'  => sub { local $^W = 0; my $item = shift; ++$item }, 
    'dec'  => sub { local $^W = 0; my $item = shift; --$item }, 
};

sub _evaluate {
    my ($self, $ops, $type) = @_;
    my ($root, $debug) = @$self{ qw( STASH DEBUG ) };
    my ($nops, $ip, $op);
    my ($x, $y, $z, $p, $e, $val, $lflag, $err);
    my (@stack, @pending, @expand);
    my $default_mode = 0;

    # return literal value intact
    return $ops unless ref($ops);

    # determine size of opcode list and preset @pending's size (plus a few 
    # extra for early expansions) before copying 
    $nops = scalar @$ops;
    $#pending = $nops + 16;
    @pending = $type ? ( $type, $ops ) : @$ops;
    @stack = ();

# DEBUG
    local $" = ', ';
    print "nops = ", $nops / 2, "\nops: [@$ops]\n" if $DEBUG;
    $ip = 0;
# /DEBUG

    while ($op = shift @pending) {
	printf("#$ip:  %02d %-8s\n", $op, $OP_NAME[$op])  if $DEBUG;
	print(scalar @pending, " items remain on pending, ", 
	      scalar @stack, " item on stack\n") if $DEBUG;
	print "stack: @stack\n" if $DEBUG;
	$ip++;

	next unless $op;		    # NULLOP

	if ($op == OP_LITERAL) {
	    # push literal text straight onto the stack
	    push(@stack, shift @pending);
	    print "  <- literal ($stack[-1])\n" if $DEBUG;
	}
	elsif ($op == OP_QUOTE) {
	    # push individual items onto front of pending op queue followed
	    # by the appropriate op (OP_STRCAT) to join them up again
	    $x = shift @pending;
	    unshift(@pending, (map { @{ $_ } } @$x), 
		    OP_STRCAT, scalar @$x);
	    print "   + ", scalar @$x, " quote items\n" if $DEBUG;
	}
	elsif ($op == OP_STRCAT) {
	    # concatentate top n items on stack
	    $x = shift @pending; 
	    push(@stack, join('', map { defined $_ ? $_ : '' } 
					splice(@stack, -$x)));
	    print "  <- strcat ($stack[-1])\n" if $DEBUG;
	}	
	elsif ($op == OP_LIST) {
	    # expand list items onto front of pending list, followed by
	    # an opcode to fold top n stack items into a list
	    $x = shift @pending;
	    unshift(@pending, (map { @$_ } @$x), OP_LISTFOLD, scalar @$x);
	    print "   + ", scalar @$x, " list items\n" if $DEBUG;
	}
	elsif ($op == OP_LISTFOLD) {
	    # pop top $item items off the stack and push a new list
	    $x = shift @pending;
	    push(@stack, [ splice(@stack, -$x) ]);
	    print("  -> pop $x items\n",
		  "  <- list ($stack[-1])\n") if $DEBUG;
	}
	elsif ($op == OP_ARGS) {
	    # args is a list of [ key => value ] or [ 0, value ] pairs.
	    # the former get converted into hash entries, the latter 
	    # into a list by extracting only the 'value' element.
	    # the hash is then added to the end of the list
	    $y = shift @pending;
	    my $hash = [];
	    @expand = ();
	    foreach $z (@$y) {
		if ($z->[0]) { push(@$hash, $z)       } # named parameter
		else         { push(@expand, $z->[1]) } # list variable
	    }
	    push(@expand, [ OP_HASH, $hash ]) if @$hash;
	    unshift(@pending, (map { @$_ } @expand), 
		    OP_LISTFOLD, scalar @expand);
	    print("   + ", scalar @expand, " list args ",
		  @$hash ? "with" : "without", " named param hash\n") 
		if $DEBUG;
	}
	elsif ($op == OP_HASH) {
	    # expand each [key, value] pair onto the stack followed by an
	    # OP_HASHFOLD to create the hash.
	    $x = shift @pending;
	    unshift(@pending, 
		    ( map { 
			( ref $_->[0] ? @{$_->[0]} : (OP_LITERAL, $_->[0]),
		          @{$_->[1]} ) 
			} @$x ), OP_HASHFOLD, scalar @$x);
	    print "   + ", scalar @$x, " hash items\n" if $DEBUG;
	}
	elsif ($op == OP_HASHFOLD) {
	    # pop top ($item * 2) items off the stack and push a new hash
	    $x = shift @pending;
	    if ($x) { push(@stack, { splice(@stack, -($x * 2)) }); }
	    else    { push(@stack, { }); } # empty hash
	    print("  -> pop $x items\n",
		  "  <- hash ($stack[-1])\n") if $DEBUG;
	}
	elsif ($op == OP_ITER) {
	    # expand list items onto front of pending list, followed by
	    # an opcode to make iterator for top n stack items 
	    ($x, $p) = splice(@pending, 0, 2);
	    unshift(@pending, (map { @$_ } @$x), @$p, 
		    OP_ITERFOLD, scalar @$x);
	    print "   + ", scalar @$x, " list items\n" if $DEBUG;
	}
	elsif ($op == OP_ITERFOLD) {
	    $x = shift @pending;  # next item is list size
	    $p = pop @stack;      # top item on stack is iterator params
	    require Template::Iterator;
	    push(@stack, 
	         Template::Iterator->new([ splice(@stack, -$x) ], @$p));
	    print("  -> pop $x items\n",
		  "  <- list ($stack[-1])\n") if $DEBUG;
	}
	elsif ($op == OP_RANGE) {
	    $x = shift @pending;
	    unshift(@pending, (map { @$_ } @$x), 
		    OP_LISTFOLD, scalar @$x, OP_RANGEFOLD);
	    print "   + range items (@$x)\n" if $DEBUG;
	}
	elsif ($op == OP_RANGEFOLD) {
	    require Template::Iterator;
	    $p = pop @stack;
	    push(@stack, Template::Iterator->new([ $p->[0] .. $p->[1] ]));
	    print "  <- range (@$p)\n" if $DEBUG;
	}
	elsif ($op == OP_BINOP) {
	    $x = shift @pending;
	    $y = $binop->{ $x };
	    warn("illegal binary op: $x\n"), return
		unless $y;
	    push(@stack, &$y(splice(@stack, -2)));
	    print("  <- binary op $x (", $stack[-1] ? 'true' : 'false', 
		  ")\n")if $DEBUG;
	}
	elsif ($op == OP_AND) {
	    # LHS has been evaluated and is on the top of the stack.
	    # RHS is the next item in pending.  This is a list reference 
	    # containing the RHS opcodes.  If LHS is false then we can 
	    # throw away the RHS and leave the false value on the stack.
	    # If LHS is true then we pop it off the stack and push the 
	    # RHS opcodes onto the front of @pending for subsequent 
	    # evaluation
	    $x = shift @pending;
	    print "  <- and (LHS: ", $stack[-1] ? 'true' : 'false', 
		  ")\n"if $DEBUG;
	    unshift(@pending, @$x), pop(@stack) if $stack[-1];
	}
	elsif ($op == OP_OR) {
	    # same as per OP_AND, with the obvious exception
	    $x = shift @pending;
	    print "  <- or (LHS: ", $stack[-1] ? 'true' : 'false', 
		  ")\n"if $DEBUG;
	    unshift(@pending, @$x), pop(@stack) unless $stack[-1];
	}
	elsif ($op == OP_NOT) {
	    $stack[-1] = ! $stack[-1];
	}
	elsif ($op == OP_DEFAULT) {
	    $default_mode = 1;
	}
	elsif ($op == OP_IDENT) {
	    $x = shift @pending;
	    push(@stack, $root);    # push root stash to resolve ident
	    @expand = ();
	    foreach (@$x) {
		($y, $p) = @$_;	    # item: [ ident/literal, params/0 ]
		push(@expand, ref $y ? @$y : (OP_LITERAL, $y));
		push(@expand, $p ? @$p : (OP_LITERAL, 0));
		push(@expand, OP_DOT);
	    }
	    unshift(@pending, @expand);
# DEBUG
	    my $iname = join('.', (map { ref($_) ? $_->[0] : $_ } @$x));
	    print "   + ident ($iname)\n" if $DEBUG;
	}
	elsif ($op == OP_ASSIGN) {
	    # the term on the RHS of the assignment is on the top of
	    # the stack.  We push a reference to the root stash and 
	    # then add pending ops to expand each element of the LHS
	    # ident WRT to the item on top of the stack (LDOT).  The
	    # final element gets an LSET operation to do the assignment
	    # e.g. foo.bar = baz  
	    #     ==>   stack: ($baz, $root) 
	    #         pending: ('foo', OP_LDOT, 'bar', OP_LSET)
	    $x = shift @pending;
	    @expand = ();
	    # coerce scalar into a list
	    $x = [ $x ] unless ref($x) eq 'ARRAY';
	    foreach (@$x) {
		# item: [ ident/literal, params/0 ] or just 'ident'
		($y, $p) = ref $_ ? @$_ : ($_, 0);   
		push(@expand, ref $y ? @$y : (OP_LITERAL, $y));
		push(@expand, $p ? @$p : (OP_LITERAL, 0));
		push(@expand, OP_LDOT);
	    }
	    # change final OP_LDOT to OP_LSET
	    $expand[-1] = OP_LSET;
	    push(@stack, $root);
	    unshift(@pending, @expand);
	    print "   + assign\n" if $DEBUG;
	}
	elsif ($op == OP_DOT || $op == OP_LDOT) {
	    ($x, $y, $p) = splice(@stack, -3);    # x.y(p)
	    $lflag = ($op == OP_LDOT);
	    $p = [] unless $p;
	    ($err, $e) = (); 

	    # can't do anything if the LHS is undef/0 or the RHS is undefined.
	    # the RHS may be 0 (e.g. mylist.0)
	    push(@stack, undef), next
		unless $x && defined $y;

	    # setting $e will trigger an exception to be raised 
	    # an exception or other error already in $err will take priority

	    if ($y =~ /^[\._]/) {
		($z, $e) = (undef, "invalid member name '$y'")
	    }
	    elsif (UNIVERSAL::isa($x, 'Template::Stash')) {
		($z, $err) = $x->get($y, $p, $self, $lflag);
## IMPLICIT CODE
		unless (defined $z || $err) {
		    # create an intermediate namespace hash if the item 
		    # doesn't exist and this is an OP_LDOT (lvalue)
		    if ($lflag) {
			$err = $x->set($y, $z = { });
		    }
		    # try to resolve undefined root variables
		    elsif ($x eq $root) {
			($z, $err) = &$z(@$p)
			    if $z = $root_ops->{ $y };
		    }
		}
	    }
	    elsif (ref($x) eq 'HASH') {
		if (defined($z = $x->{ $y })) {
		    ($z, $err) = &$z(@$p)   # execute any code binding
			if $z && ref($z) eq 'CODE';
## CODE
		}
		elsif ($lflag) {
		    # create empty hash if OP_LDOT
		    $z = $x->{ $y } = { } if $lflag;
		}
		else {
		    ($z, $err) = &$z($x) 
			if $z = $hash_ops->{ $y };
		}
	    }
	    elsif (UNIVERSAL::isa($x, 'ARRAY') 
		   && (($z = $list_ops->{ $y }) || ($y =~ /^\d+$/))) {
		# if the target is a list we try to apply the operations
		# in $list_ops or apply a numerical operation as an index
		if ($z) {
		    ($z, $err) = &$z($x);
		}
		else {
		    $z = $x->[$y];
		}
	    }
	    elsif (ref($x)) {
		eval { ($z, $err) = $x->$y(@$p); };
		$e = $@ if $@;
	    }
	    else {
		$e = "don't know how to access [ $x ].$y";
	    }

	    $e = "$y is undefined"	# NOTE $err may be defined and 0
		if $debug && ! defined $z && ! $e && ! defined $err;

	    # throw an exception into $err if $e is defined unless $err
	    # is already set
	    $err = $self->throw(ERROR_UNDEF, $e) 
		if $e && ! $err;
	    return (undef, $err) if $err;

	    push(@stack, $z);
	    print "  <- dot (", $stack[-1] || '<undef>', ")\n" if $DEBUG;
	}
	elsif ($op == OP_LSET) {
	    ($z, $x, $y, $p) = splice(@stack, -4);   # x.y(p) = z

	    push(@stack, undef), next
		unless $x && defined $y;

	    if ($y =~ /^[\._]/) {
		($z, $e) = (undef, "invalid member name '$y'")
	    }
	    elsif (UNIVERSAL::isa($x, 'Template::Stash')) {
		$err = $x->set($y, $z, $self)
		    unless ($default_mode 
			    && (($val, $err) = $x->get($y, $p, $self))
			    && $val);
	    }
	    elsif (ref($x) eq 'HASH') {
		$x->{ $y } = $z
		    unless $default_mode && $x->{ $y };
	    }
	    elsif (ref($x)) {
		eval { ($z, $err) = $x->$y($z)
			   unless ($default_mode 
				   && (($val, $err) = $x->$y())
				   && $val);
		};
		$e = $@ if $@;
	    }
	    else {
		$e = "don't know how to assign to [ $x ].$y";
	    }

	    $err = $self->throw(ERROR_UNDEF, $e) 
		if $e && ! $err;
	    return (undef, $err) if $err;

	    push(@stack, $z);
	    print "  <- lset ($stack[-1])\n" if $DEBUG;
	}
	else {
	    print "Bad, bad OP ($op).\n";
	}
	
    }
    pop @stack;
}
    

#------------------------------------------------------------------------
# oplist_dump(\@oplist)
#
# Debug method to print opcode list.
#------------------------------------------------------------------------

sub oplist_dump {
    my ($self, $oplist) = @_;

    foreach my $op (@$oplist) {
	if (ref($op)) {
	    print STDERR "oplist + $op->[0]\n";
	}
	else {
	    print STDERR "oplist * $op ($OP_NAME[$op])\n";
	}
    }
}



1;

__END__

=head1 NAME

Template::Context - object class representing a runtime context in which templates are rendered.

=head1 SYNOPSIS

    use Template::Context;

    $context = Template::Context->new(\%cfg);

    $error   = $context->process($template);

    # cleanup
    $context->old();

    $context->localise(\%vars);
    $context->delocalise();

    $context->output($text);
    $context->error($text);
    $context->redirect($what, $where);

    $context->throw($type, $info);
    $context->catch($type, $handler);

    ($plugin, $error) = $context->use_plugin($name, \@params);
    ($filter, $error) = $context->use_filter($name, \@params, $alias);

=head1 DESCRIPTION

The Template::Context module defines an object which represents a runtime
context in which a template is rendered.  The context reference is passed 
down through the processing engine, allowing template directives and user 
code to generate output, retrieve and update variable values, render
other template documents, and so on.

The context defines the variables that exist for the template to
access and what values they have (a task delegated to a
L<Template::Stash|Template::Stash> object).  The localise() and
delocalise() methods are provided to handle localisation of the 
stash.

The context also maintains a reference to a cache of previously
compiled templates and has the facility to load, parse and compile new
template documents as they are requested.  These templates can then be 
accessed from within other templates via the "INCLUDE template_name" 
directive or may be rendered by a direct call from a template processing
engine.  The L<Template::Cache|Template::Cache> manages the template 
documents for the context  and delegates the parsing of new templates to 
a L<Template::Parser|Template::Parser> object.  A cache may be shared
among multiple context objects allowing common templates documents to
be compile only once and rendered many times in different contexts.

In addition, the context provides facilities for loading plugins and 
filters.

The context object provides template output and error handling methods 
which can output/delegate to a user-supplied file handle, text string or
sub-routine.  These handlers are defined using the redirect() method.

=head1 AUTHOR

Andy Wardley E<lt>cre.canon.co.ukE<gt>

=head1 REVISION

$Revision: 1.34 $

=head1 COPYRIGHT

Copyright (C) 1996-1999 Andy Wardley.  All Rights Reserved.
Copyright (C) 1998-1999 Canon Research Centre Europe Ltd.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=head1 SEE ALSO

L<Template|Template>

=cut

