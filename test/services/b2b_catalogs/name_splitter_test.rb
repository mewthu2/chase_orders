require 'test_helper'

class B2bCatalogs::NameSplitterTest < ActiveSupport::TestCase
  test 'products sharing a prefix form a style and the rest is the color' do
    result = B2bCatalogs::NameSplitter.split(['Legging Apex Seamless Ash', 'Legging Apex Seamless Sky'])

    assert_equal ['Legging Apex Seamless', 'Ash'], result['Legging Apex Seamless Ash']
    assert_equal ['Legging Apex Seamless', 'Sky'], result['Legging Apex Seamless Sky']
  end

  test 'multi-word colors are kept whole when a sibling shares the style' do
    result = B2bCatalogs::NameSplitter.split(['Legging Pure Seamless Tibetan Red', 'Legging Pure Seamless Black'])

    assert_equal ['Legging Pure Seamless', 'Tibetan Red'], result['Legging Pure Seamless Tibetan Red']
  end

  test 'a product without siblings uses the last word as the color' do
    result = B2bCatalogs::NameSplitter.split(['Top Harmony Pink', 'Legging Caos Seamless Tibetan Red'])

    assert_equal ['Top Harmony', 'Pink'], result['Top Harmony Pink']
    assert_equal ['Legging Caos Seamless Tibetan', 'Red'], result['Legging Caos Seamless Tibetan Red']
  end

  test 'a one-word name is its own style with no color' do
    assert_equal ['Meia', ''], B2bCatalogs::NameSplitter.split(['Meia'])['Meia']
  end
end
