use strict;
use warnings;
package DBIx::Class::ResultSet::RecursiveUpdate;

our $VERSION = '0.013';

use base qw(DBIx::Class::ResultSet);

sub recursive_update {
    my ( $self, $updates, $fixed_fields ) = @_;
    return DBIx::Class::ResultSet::RecursiveUpdate::Functions::recursive_update(
        resultset    => $self,
        updates      => $updates,
        fixed_fields => $fixed_fields
    );
}

package DBIx::Class::ResultSet::RecursiveUpdate::Functions;
use Carp;
use Scalar::Util qw( blessed );


sub recursive_update {
    my %params = @_;
    my ( $self, $updates, $fixed_fields, $object, $resolved, $if_not_submitted ) = @params{ qw/resultset updates fixed_fields object resolved if_not_submitted/ }; 
    $resolved ||= {};
    # warn 'entering: ' . $self->result_source->from();
    carp 'fixed fields needs to be an array ref' if $fixed_fields && ref($fixed_fields) ne 'ARRAY';
    my %fixed_fields;
    %fixed_fields = map { $_ => 1 } @$fixed_fields if $fixed_fields;
    if ( blessed($updates) && $updates->isa('DBIx::Class::Row') ) {
        return $updates;
    }
    if ( $updates->{id} ){
        $object = $self->find( $updates->{id}, { key => 'primary' } );
    }
    my @missing =
      grep { !exists $updates->{$_} && !exists $fixed_fields{$_} } $self->result_source->primary_columns;
    if ( !$object && !scalar @missing ) {
#        warn 'finding by: ' . Dumper( $updates ); use Data::Dumper;
        $object = $self->find( $updates, { key => 'primary' } );
    }
    $updates = { %$updates, %$resolved };
    @missing =
      grep { !exists $resolved->{$_} } @missing;
    if ( !$object && !scalar @missing ) {
#        warn 'finding by +resolved: ' . Dumper( $updates ); use Data::Dumper;
        $object = $self->find( $updates, { key => 'primary' } );
    }
    $object ||= $self->new( {} );
    # warn Dumper( $updates ); use Data::Dumper;
    # direct column accessors
    my %columns;

    # relations that that should be done before the row is inserted into the database
    # like belongs_to
    my %pre_updates;

    # relations that that should be done after the row is inserted into the database
    # like has_many and might_have
    my %post_updates;
    my %other_methods;
    my %columns_by_accessor = _get_columns_by_accessor( $self );
#    warn 'resolved: ' . Dumper( $resolved );
#    warn 'updates: ' . Dumper( $updates ); use Data::Dumper;
#    warn 'columns: ' . Dumper( \%columns_by_accessor );
    for my $name ( keys %$updates ) {
        my $source = $self->result_source;
        if ( $columns_by_accessor{$name}
            && !( $source->has_relationship($name) && ref( $updates->{$name} ) )
          )
        {
            $columns{$name} = $updates->{$name};
            next;
        }
        if( !( $source->has_relationship($name) ) ){
            $other_methods{$name} = $updates->{$name};
            next;
        }
        my $info = $source->relationship_info($name);
        if (
            _master_relation_cond(
                $source, $info->{cond}, _get_pk_for_related( $self, $name)
            )
          )
        {
            $pre_updates{$name} = $updates->{$name};
        }
        else {
            $post_updates{$name} = $updates->{$name};
        }
    }
    # warn 'other: ' . Dumper( \%other_methods ); use Data::Dumper;

    # first update columns and other accessors - so that later related records can be found
    for my $name ( keys %columns ) {
        $object->$name( $columns{$name} );
    }
    for my $name ( keys %other_methods) {
        $object->$name( $updates->{$name} ) if $object->can( $name );
    }
    for my $name ( keys %pre_updates ) {
        my $info = $object->result_source->relationship_info($name);
        _update_relation( $self, $name, $updates, $object, $info, $if_not_submitted );
    }
#    $self->_delete_empty_auto_increment($object);
# don't allow insert to recurse to related objects - we do the recursion ourselves
#    $object->{_rel_in_storage} = 1;

    $object->update_or_insert if $object->is_changed;

    # updating many_to_many
    for my $name ( keys %$updates ) {
        next if exists $columns{$name};
        my $value = $updates->{$name};

        if ( is_m2m( $self, $name) ) {
            my ($pk) = _get_pk_for_related( $self, $name);
            my @rows;
            my $result_source = $object->$name->result_source;
            my @updates;
            if( ! defined $value ){
                next;
            }
            elsif( ref $value ){
                @updates = @{ $value };
            }
            else{
                @updates = ( $value );
            }
            for my $elem ( @updates ) {
                if ( ref $elem ) {
                    push @rows, recursive_update( resultset => $result_source->resultset, updates => $elem );
                }
                else {
                    push @rows,
                      $result_source->resultset->find( { $pk => $elem } );
                }
            }
            my $set_meth = 'set_' . $name;
            $object->$set_meth( \@rows );
        }
    }
    for my $name ( keys %post_updates ) {
        my $info = $object->result_source->relationship_info($name);
        _update_relation( $self, $name, $updates, $object, $info, $if_not_submitted );
    }
    return $object;
}

sub _get_columns_by_accessor {
    my $self   = shift;
    my $source = $self->result_source;
    my %columns;
    for my $name ( $source->columns ) {
        my $info = $source->column_info($name);
        $info->{name} = $name;
        $columns{ $info->{accessor} || $name } = $info;
    }
    return %columns;
}

sub _update_relation {
    my ( $self, $name, $updates, $object, $info, $if_not_submitted ) = @_;
    my $related_result =
      $self->related_resultset($name)->result_source->resultset;
    my $resolved;
    if( $self->result_source->can( '_resolve_condition' ) ){
        $resolved = $self->result_source->_resolve_condition( $info->{cond}, $name, $object );
    }
    else{
        $resolved = $self->result_source->resolve_condition( $info->{cond}, $name, $object );
    }

 #                    warn 'resolved: ' . Dumper( $resolved ); use Data::Dumper;
    $resolved = {}
      if defined $DBIx::Class::ResultSource::UNRESOLVABLE_CONDITION && $DBIx::Class::ResultSource::UNRESOLVABLE_CONDITION == $resolved;
    if ( ref $updates->{$name} eq 'ARRAY' ) {
        my @updated_ids;
        for my $sub_updates ( @{ $updates->{$name} } ) {
            my $sub_object =
              recursive_update( resultset => $related_result, updates => $sub_updates, resolved => $resolved );
            push @updated_ids, $sub_object->id;
        }
        my @related_pks = $related_result->result_source->primary_columns;
        if( defined $if_not_submitted && $if_not_submitted eq 'delete' ){
            if ( 1 == scalar @related_pks ){
                $object->$name->search( { $related_pks[0] => { -not_in => \@updated_ids } } )->delete;
            }
        }
        elsif( defined $if_not_submitted && $if_not_submitted eq 'set_to_null' ){
            if ( 1 == scalar @related_pks ){
                my @fk = keys %$resolved;
                $object->$name->search( { $related_pks[0] => { -not_in => \@updated_ids } } )->update( { $fk[0] => undef } );
            }
        }
    }
    else {
        my $sub_updates = $updates->{$name};
        my $sub_object;
        if( ref $sub_updates ){
            # for might_have relationship
            if( $info->{attrs}{accessor} eq 'single' && defined $object->$name ){
                $sub_object = recursive_update( 
                    resultset => $related_result, 
                    updates => $sub_updates, 
                    object =>  $object->$name 
                );
            }
            else{
                $sub_object =
                recursive_update( resultset => $related_result, updates => $sub_updates, resolved => $resolved );
            }
        }
        elsif( ! ref $sub_updates ){
            $sub_object = $related_result->find( $sub_updates ) 
                unless (!$sub_updates && (exists $info->{attrs}{join_type} && $info->{attrs}{join_type} eq 'LEFT'));
        }
        $object->set_from_related( $name, $sub_object )
          unless (!$sub_object && !$sub_updates && (exists $info->{attrs}{join_type} && $info->{attrs}{join_type} eq 'LEFT'));
    }
}

sub is_m2m {
    my ( $self, $relation ) = @_;
    my $rclass = $self->result_class;

    # DBIx::Class::IntrospectableM2M
    if ( $rclass->can('_m2m_metadata') ) {
        return $rclass->_m2m_metadata->{$relation};
    }
    my $object = $self->new( {} );
    if (    $object->can($relation)
        and !$self->result_source->has_relationship($relation)
        and $object->can( 'set_' . $relation ) )
    {
        return 1;
    }
    return;
}

sub get_m2m_source {
    my ( $self, $relation ) = @_;
    my $rclass = $self->result_class;

    # DBIx::Class::IntrospectableM2M
    if ( $rclass->can('_m2m_metadata') ) {
        return $self->result_source->related_source(
            $rclass->_m2m_metadata->{$relation}{relation} )
          ->related_source(
            $rclass->_m2m_metadata->{$relation}{foreign_relation} );
    }
    my $object = $self->new( {} );
    my $r = $object->$relation;
    return $r->result_source;
}

sub _delete_empty_auto_increment {
    my ( $self, $object ) = @_;
    for my $col ( keys %{ $object->{_column_data} } ) {
        if (
            $object->result_source->column_info($col)->{is_auto_increment}
            and ( !defined $object->{_column_data}{$col}
                or $object->{_column_data}{$col} eq '' )
          )
        {
            delete $object->{_column_data}{$col};
        }
    }
}

sub _get_pk_for_related {
    my ( $self, $relation ) = @_;
    my $result_source;
    if ( $self->result_source->has_relationship($relation) ) {
        $result_source = $self->result_source->related_source($relation);
    }

    # many to many case
    if ( is_m2m($self, $relation) ) {
        $result_source = get_m2m_source($self, $relation);
    }
    return $result_source->primary_columns;
}

sub _master_relation_cond {
    my ( $source, $cond, @foreign_ids ) = @_;
    my $foreign_ids_re = join '|', @foreign_ids;
    if ( ref $cond eq 'HASH' ) {
        for my $f_key ( keys %{$cond} ) {

            # might_have is not master
            my $col = $cond->{$f_key};
            $col =~ s/self\.//;
            if ( $source->column_info($col)->{is_auto_increment} ) {
                return 0;
            }
            if ( $f_key =~ /^foreign\.$foreign_ids_re/ ) {
                return 1;
            }
        }
    }
    elsif ( ref $cond eq 'ARRAY' ) {
        for my $new_cond (@$cond) {
            return 1
              if _master_relation_cond( $source, $new_cond, @foreign_ids );
        }
    }
    return;
}

1;    # Magic true value required at end of module
__END__

=head1 NAME

DBIx::Class::ResultSet::RecursiveUpdate - like update_or_create - but recursive

=head1 SYNOPSIS

The functional interface:

    my $new_item = DBIx::Class::ResultSet::RecursiveUpdate::Functions::recursive_update({ 
        resultset => $schema->resultset( 'Dvd' ),
        updates => {
            id => 1, 
            owned_dvds => [ 
                { 
                  title => 'One Flew Over the Cuckoo's Nest' 
                } 
            ] 
        }
    });


As ResultSet subclass:

    __PACKAGE__->load_namespaces( default_resultset_class => '+DBIx::Class::ResultSet::RecursiveUpdate' );

in the Schema file (see t/lib/DBSchema.pm).  Or appropriate 'use base' in the ResultSet classes. 

Then:

    my $user = $user_rs->recursive_update( { 
        id => 1, 
        owned_dvds => [ 
        { 
          title => 'One Flew Over the Cuckoo's Nest' 
        } 
        ] 
      }
    );

  
=head1 DESCRIPTION

This is still experimental. I've added a functional interface so that it can be used 
in Form Processors and not require modification of the model.

You can feed the ->create method with a recursive data structure and have the related records
created.  Unfortunately you cannot do a similar thing with update_or_create - this module
tries to fill that void. 

It is a base class for ResultSets providing just one method: recursive_update
which works just like update_or_create but can recursively update or create
data objects composed of multiple rows. All rows need to be identified by primary keys
- so you need to provide them in the update structure (unless they can be deduced from 
the parent row - for example when you have a belongs_to relationship).  
If not all columns comprising the primary key are specified - then a new row will be created,
with the expectation that the missing columns will be filled by it (as in the case of auto_increment 
primary keys).  


If the result-set itself stores an assignment for the primary key, 
like in the case of:
    
    my $restricted_rs = $user_rs->search( { id => 1 } );

then you need to inform recursive_update about additional predicate with a second argument:

    my $user = $restricted_rs->recursive_update( { 
        owned_dvds => [ 
        { 
          title => 'One Flew Over the Cuckoo's Nest' 
        } 
        ] 
      },
      [ 'id' ]
    );

This will work with a new DBIC release.

For a many_to_many (pseudo) relation you can supply a list of primary keys
from the other table - and it will link the record at hand to those and
only those records identified by them.  This is convenient for handling web
forms with check boxes (or a SELECT box with multiple choice) that let you
update such (pseudo) relations.  

For a description how to set up base classes for ResultSets see load_namespaces
in DBIx::Class::Schema.

=head1 DESIGN CHOICES

=head2 Treatment of many to many pseudo relations

The function gets the information about m2m relations from DBIx::Class::IntrospectableM2M.
If it is not loaded in the ResultSource classes - then the code relies on the fact that:
    if($object->can($name) and
             !$object->result_source->has_relationship($name) and
             $object->can( 'set_' . $name )
         )

then $name must be a many to many pseudo relation.  And that in a
similarly ugly was I find out what is the ResultSource of objects from
that many to many pseudo relation.


=head1 INTERFACE 

=head1 METHODS

=head2 recursive_update

The method that does the work here.

=head2 is_m2m

$self->is_m2m( 'name ' ) - answers the question if 'name' is a many to many
(pseudo) relation on $self.

=head2 get_m2m_source

$self->get_m2m_source( 'name' ) - returns the ResultSource linked to by the many
to many (pseudo) relation 'name' from $self.


=head1 DIAGNOSTICS


=head1 CONFIGURATION AND ENVIRONMENT

DBIx::Class::RecursiveUpdate requires no configuration files or environment variables.

=head1 DEPENDENCIES

    DBIx::Class

=head1 INCOMPATIBILITIES

=for author to fill in:

None reported.


=head1 BUGS AND LIMITATIONS

=for author to fill in:

No bugs have been reported.

Please report any bugs or feature requests to
C<bug-dbix-class-recursiveput@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.


=head1 AUTHOR

Zbigniew Lukasiak  C<< <zby@cpan.org> >>
Influenced by code by Pedro Melo.

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2008, Zbigniew Lukasiak C<< <zby@cpan.org> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.


=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.
